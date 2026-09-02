# Crypto Design — E2E Vault (Phase 2)

> Scope (Patches 1–5 implemented): package decision, primitives, key hierarchy,
> AAD scheme, BIP39 recovery, password/normalization decision, validation bounds,
> encrypted vault store + migration; **Patch 4: setup/unlock/recovery UI + session
> lock (`VaultLockCubit`, lifecycle lock) + `KeyAttributesStore` + reset + UI
> redesign** (the design system is kept local); **Patch 5: biometric unlock
> shortcut (3rd wrap + OS-keystore access control)** — see §11. Phase 3 sync envelopes: §12–14.
> Screen-capture protection (`SecureScreenScope`, ref-counted): §15.

## 1. Package decision — `sodium 3.4.6` + `sodium_libs 3.4.6+4`

- **Why not 4.x:** `sodium 4.x` requires Dart SDK `^3.11.0`. The project is on Dart `3.10.7`
  (Flutter 3.38.6 stable) → 4.x is **unresolvable** (`flutter pub get` rejects it).
- **Is `sodium_libs` "discontinued"?** The pub.dev tag says so; however, the package
  bundles pre-built libsodium binaries, **does NOT REQUIRE native-assets / the `--enable-experiment`
  flag**, and the 3.x line works flawlessly on stable Flutter
  (proven via `integration_test/`). For this reason, 3.x is a deliberate and correct decision.
- **Going forward:** once Flutter moves to Dart 3.11+, migrating to `sodium 4.x` with native-assets
  becomes a separate, small migration (only the init line + import change; the algorithm stays the same).
- **Init:** `SodiumSumoInit.init()` → `SodiumSumo` (`pwhash` = Argon2id is available only
  in the *sumo* build).

## 2. Primitives

| Purpose | Algorithm | sodium API |
|------|-----------|------------|
| KDF (password → KEK) | **Argon2id** (moderate ops/mem) | `crypto.pwhash(alg: argon2id13)` |
| AEAD (data + key wrapping) | **XChaCha20-Poly1305 IETF** | `crypto.aeadXChaCha20Poly1305IETF` |
| Randomness | libsodium CSPRNG | `randombytes.buf`, `secureRandom` |

- `crypto_secretbox` is **NOT USED** (IETF AEAD chosen for AAD support + nonce-misuse resistance).
- The nonce is **random** on every encryption (`randombytes.buf(nonceBytes)`); the XChaCha 24-byte
  nonce → safe to randomize, and is stored alongside the ciphertext.
- **Argon2id is mandatory in a separate isolate** (`runIsolated`): pwhash takes seconds and would block
  the UI. Inside the isolate the password is converted to an `Int8List`, then zero-filled after the operation.

## 3. Key hierarchy (Ente model)

```
masterKey  : 32-byte random — the ACTUAL data key (encrypts the tokens)
             ↑ NEVER written to disk in plaintext; only held in memory during the session (KeyHandle)

masterPassword ──Argon2id(salt,ops,mem)──▶ KEK ──wrap──▶ encryptedMasterKey
recoveryKey (32-byte random, BIP39) ─────────wrap──▶ recoveryEncryptedMasterKey
biometricKey (32-byte random, OS-gated) ─────wrap──▶ biometricEncryptedMasterKey  (Patch 5, optional)
```

- The password **or** the recovery key **or** (if enabled) biometrics unlocks the masterKey — all three
  wrap the same masterKey. Biometrics is only a *shortcut*; password + recovery always work.
- **Changing the password** does not change the masterKey → token ciphertexts are not
  re-encrypted; only a new salt + new KEK + new `encryptedMasterKey` are written.
  `recoveryEncryptedMasterKey` is left untouched.
- `KeyHandle` is an opaque wrapper → sodium's `SecureKey` type does not leak into the domain/public API.
  Raw key bytes exist only inside the wrap/unwrap helpers, immediately followed by `fillRange(0)`.

## 4. AAD (Additional Authenticated Data) scheme

The AEAD additionalData field cryptographically binds the context → a blob cannot be decrypted in another
context (e.g. a masterKey-wrap blob cannot be opened as a token).

| Context | AAD (UTF-8/codeUnits) |
|--------|------------------------|
| masterKey ← KEK | `masterkey-kek\|1` |
| masterKey ← recovery key | `masterkey-recovery\|1` |
| masterKey ← biometricKey (Patch 5) | `masterkey-biometric\|1` |
| Token record (Patch 3) | `token\|1\|<id>` |
| Encrypted backup (Phase 5) | `backup\|<v>\|<kdf.alg>\|<opslimit>\|<memlimit>\|<base64 salt>\|<cipher.alg>` |

## 5. Recovery key — our own BIP-39 implementation

- The canonical `bip39` package has been unmaintained/unverified for years → **kept outside the trust boundary**.
  We wrote our own `encode`/`decode` (encoding + checksum only; not a crypto routine).
- 256-bit entropy → SHA-256 first byte (8-bit checksum) → 24 × 11-bit → words.
- **Wordlist:** the official BIP-0039 English 2048 words (bitcoin/bips, `english.txt`).
  SHA-256 `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`.
  **License: MIT** (BIP-0039 "This BIP falls under the MIT License"; the bitcoin/bips root
  LICENSE is MIT — confirmed 2026-06-07). Attribution at the top of `bip39_wordlist.dart`.
- `decode` verifies the checksum → typos / wrong words are caught
  (`FormatException`). Validated against the official Trezor 256-bit test vectors.

## 6. Password normalization decision

- Dart core has **NO NFKC normalizer** → to avoid adding an extra dependency,
  **no normalization is performed; the password is hashed as its raw UTF-8 bytes**.
- Result: the password is used exactly as entered (a common, safe choice).
- If Unicode password UX is desired later, normalize-on-input will be handled separately.

## 7. Domain password policy

Because `KeyManager` is a security boundary, the minimum rule is enforced here in addition to the
UI validator (`WeakPasswordException`). `KeyManager` is the **single source of truth**
(`minPasswordLength`, `minPasswordClasses`, `passwordClassCount`, `meetsPolicy`) — the setup screen's
strength meter reads the same constants:
- empty after trim → reject
- `< KeyManager.minPasswordLength` (**12**, raised from 8 on 2026-06-19) → reject
- fewer than `KeyManager.minPasswordClasses` (**3**) distinct character classes
  (upper / lower / digit / symbol) → reject
- The policy check is trimmed, but **the actual KEK derivation uses the password verbatim**.

The setup screen shows a strength meter that is **not color-only** (bar + icon + text label +
`Semantics`), so the signal survives color-blindness and screen readers. Length alone is not
enough: a long single-class passphrase is rejected — that case has its own integration test.

## 8. Strict metadata/blob validation (early detection of corrupt/future schemas)

Corrupt or future-version metadata is rejected **early**, before it reaches sodium —
otherwise a late sodium error looks like a "wrong password", or a future schema is
misinterpreted (`FormatException`):

| Field | Rule |
|------|-------|
| `EncryptedBlob.version` | `1..supportedVersion` |
| `EncryptedBlob` nonce | exactly `24` bytes (XChaCha IETF) |
| `EncryptedBlob` ciphertext | at least `16` bytes (Poly1305 tag) |
| `KeyAttributes.version` | `1..supportedVersion` |
| `KeyAttributes.kdfSalt` | exactly `16` bytes (`crypto_pwhash_SALTBYTES`) |
| `KeyAttributes.kdfOps/kdfMem` | positive integer (a fractional `num` is rejected) |

JSON parsing does not use `as` casts; type-safe helpers (`_asString/_asInt/_asMap`) turn a
wrong type → `FormatException`. A fractional `num` (e.g. `ops: 1.5`) is not silently truncated;
an integer-valued double (`3.0`) is accepted.

## 9. Encrypted vault store + migration (Patch 3)

**`EncryptedVaultRepository`** (`vault_encrypted_v1`) — a per-token encrypted record:
```
{ id, v, n(nonce b64), c(ciphertext b64), updatedAt(epoch ms), deleted }
```
- plaintext = `OtpAccount.toJson()` → UTF-8 → `encrypt(aad: token|1|<id>)`.
- **Record plaintext schema** (what `OtpAccount.toJson()` produces):
  ```
  { id, secret, type, issuer?, accountName, algorithm, digits, period, counter, tags? }
  ```
  `issuer` and `tags` are written **only when present/non-empty**; every other key is always there.
- **`tags` (optional, Phase 5 Patch 3).** A list of at most 8 user labels, each at most 32 runes,
  normalized by `OtpAccount.normalizeTags` (trim → drop blanks → clip → drop exact duplicates → keep
  the first 8). It lives **inside the encrypted blob**, so a label like "Work" or "Bank" is as opaque
  to the server as the secret is; nothing about tags is added to the record envelope, and the admin
  panel cannot count them.
  **The AAD and the record `v` are UNCHANGED — deliberately.** A new optional key inside the
  plaintext changes neither how the blob is opened nor what it is bound to: the AAD's job is to pin
  the record to its context (`token|1|<id>`), and the id, the context and the cipher are all the same.
  Bumping `v` (or the AAD) would instead make every pre-Patch-3 client reject the **whole** vault as a
  future schema (§8) rather than quietly ignore one key it does not know — turning an additive field
  into a total outage on the older device. So §4's table needs no new row.
  Two consequences follow from the same choice, and both are accepted:
  - `toJson` omits the key entirely when the list is empty, so an untagged account serializes
    byte-identically to a pre-Patch-3 one. Upgrading a vault therefore re-encrypts nothing, refreshes
    no `updatedAt` and pushes nothing (the unchanged-blob shortcut below sees no change).
  - An older client that **edits** a tagged token writes the plaintext back without the key it never
    read, so those tags are lost on every device (risk R1). Reading, syncing and generating codes on
    an old client are all safe; only an edit drops them.
- `deleted` is always `false` in Phase 2 (soft-delete requires the Phase 3 API expansion —
  `save(List)` replace semantics cannot produce a tombstone).
- **Unchanged-blob protection:** `save()` re-encrypts only the new/changed record
  (via the `OtpAccount` Equatable comparison); it preserves the unchanged old blob +
  its `updatedAt`. The whole vault is not re-encrypted when a HOTP counter increments.
- **Corrupt-record protection:** raw records that cannot be decoded/decrypted are kept
  in memory and written back VERBATIM on `save()` (even a non-map scalar/null → no cast,
  verbatim). Even if the user adds a token despite the banner, the corrupt record is not dropped.
- **No silent data loss:** a top-level malformed/non-list value OR a fully-undecryptable record
  → `VaultIntegrityException` (an empty vault is not shown). A partial case → `corruptedCount`.
- **Mutation rejection in the integrity state (protection against unconfirmed overwrite):**
  when `VaultIntegrityException` is thrown, `load()` returns EARLY → the repo cache
  (`_lastById`/`_corruptedRaw`) stays EMPTY. If a `save()` runs in this state, then because
  the cache is empty, the corrupt-but-possibly-recoverable raw vault on disk would be
  OVERWRITTEN with only the new content (without the user's explicit "Reset vault" confirmation).
  For this reason the mutation is **rejected at the state-machine level:** if `add`/`removeById`/`incrementCounter`
  is called while `state.error != null`, `VaultCubit` throws a `StateError` (caught by the UI → SnackBar;
  not a silent no-op). An additional defense layer: `VaultPage` hides the add FAB on the
  integrity screen. (General principle: every write path that assumes "the repo cache is
  populated on load" must also be safe in the states where load returns early — hiding the
  UI alone is not enough, since the UI can be bypassed.)
- `purgeCorrupted()` deletes corrupt records only with explicit user confirmation;
  it does not touch healthy + unchanged blobs.

**`VaultMigration`** (Phase 1 plaintext → encrypted, one-time):
- A separate **commit marker** `vault_migration_v1="committed"` (idempotency; it does not fall into
  the "encrypted data exists, so no-op" trap).
- Flow: marker committed → no-op · no plaintext → write marker · plaintext exists →
  **read the existing encrypted data + id-based MERGE** (the existing encrypted record wins, missing
  plaintext is added) → save → read back + verify → delete plaintext → write marker.
- Crash-safe: on a half-finished migration (no marker + plaintext exists + another record
  in encrypted) it runs again, and thanks to **upsert** it does not overwrite what exists + no duplicates.
  If load throws an integrity error, it performs no destructive step (no plaintext deletion / no marker).

## 10. Test strategy

- **Pure-Dart (`test/`, plain `flutter test`):** `EncryptedBlob`, `KeyAttributes`
  JSON+validation, `Bip39` (no libsodium required).
- **Integration (`integration_test/`, device/simulator):** `SodiumCryptoService`,
  `KeyManager`, `EncryptedVaultRepository`/`VaultMigration` — real libsodium is
  required; the `sodium_libs` platform plugin does not load on the plain `flutter test`
  VM host (`SodiumPlatform.instance` error). The in-memory `FakeSecureStorage`
  faithfully models storage behavior without touching the Keychain.
- **Biometrics (Patch 5):** the `KeyManager.enrollBiometric`/`biometricUnlock` round-trip
  runs in integration_test (real wrap/unwrap). `VaultLockCubit` biometric flows
  (enable/disable atomicity, retrieve error paths, lifecycle inactive-vs-paused)
  run on the host with `FakeBiometricService`. `BiometricServiceImpl` (real `local_auth` +
  OS-keystore) requires a REAL device → does not run in CI; the manual verification checklist is §11.

## 11. Biometric unlock (Patch 5)

**Goal:** a biometric shortcut in place of the password — WITHOUT WEAKENING the E2E model. The masterKey
can always be unlocked with password + recovery too; biometrics merely opens a 3rd wrap path.

**The security boundary = OS keystore access control** (NOT the `local_auth` boolean):
- `biometricKey` (32-byte random) wraps `masterKey` with the `masterkey-biometric|1` AAD
  → `biometricEncryptedMasterKey` (`KeyAttributes.bmk`, optional field).
- The RAW bytes of `biometricKey` are stored in `flutter_secure_storage` **with separate options/namespace**
  (`vault_biometric_key_v1`), **under biometric access control**:
  - **iOS:** `useSecureEnclave: true` + `AccessControlFlag.biometryCurrentSet`
    (`KeychainAccessibility.passcode`). **`biometryCurrentSet` → when the biometric set changes
    (a new finger/face is added or removed) the key is AUTOMATICALLY invalidated** → the user unlocks
    once with the password and re-enrolls from Settings (NO token loss). Even if an attacker adds
    their own biometrics to a stolen device, the old key is invalid.
  - **Android:** `AndroidOptions.biometric(enforceBiometrics: true,
    biometricType: strongBiometricOnly)` → the Keystore AES key is bound via
    `setUserAuthenticationRequired` to **strong biometrics only** (PIN/pattern
    is rejected). `strongBiometricOnly` → `biometricPromptNegativeButton` is required. API 28+.
- The **REAL prompt** at unlock comes from the OS gate inside `storage.read()` (a SINGLE prompt; `local_auth`
  is used only for the availability check → no double prompt). The `biometricKey` bytes are NEVER
  cached in Dart — they are re-read from the gate on every unlock and `fillRange(0)`'d after use.

**Threat model:** stolen-and-locked device → the gate does not open; rooted → the key is non-exportable
in the TEE/Keystore (a boolean spoof is useless, and we do not trust the boolean anyway); backup → even if
the `bmk` ciphertext is backed up, the wrapping key cannot be backed up (Secure Enclave / userAuthenticationRequired).

**Availability (Android strong + SDK):** in Dart there is no access to `flutter_secure_storage`'s native
strong-availability → `local_auth.getAvailableBiometrics().contains(strong)`
+ `device_info_plus` `sdkInt >= 28`. On iOS, Face/Touch ID is already strong.

**Lifecycle:** the biometric system prompt can briefly produce `inactive`; while `_biometricPromptInFlight`
is true, `inactive` is exempt from the abort (a successful unlock is not interrupted), while `paused` (a real background)
still triggers a definite abort. Identical to `_abortToBackground` + ownership `unlock()`.

**Reset/disable:** the `bmk` OS key lives in a separate namespace → `resetVault` + `disableBiometric`
explicitly call `BiometricService.disable()` (the default `_deleteKeys` is not enough).

**Manual device verification checklist** (does not run in CI):
1. Enable from Settings → kill the app → biometric button on UnlockPage → successful unlock.
2. Change the biometric set (add a new finger) → biometrics fails (`KeyMissing`) → fall back to password,
   `bmk` is cleared → re-enroll from Settings.
3. Lockout (too many attempts) → fall back to password. App<28 (Android) → the button never appears.

## 12. Cloud metadata sync (Phase 3 Patch 2)

**Goal:** back up `key_attributes` to the server and restore them on a new device — WITHOUT WEAKENING E2E.
NOT token sync (that is Patch 3).

**What goes to the server (all already opaque):**
- `kdf_salt`, `kdf_ops`, `kdf_mem` — KDF parameters (to derive password → KEK; not the password itself).
- `encrypted_master_key` + `master_key_nonce` — the masterKey wrapped with the KEK (`masterkey-kek|1` AAD).
- `recovery_encrypted_master_key` + `recovery_nonce` — the masterKey wrapped with the recovery key.

**What NEVER goes to the server:** `masterKey` (raw), `KEK`, `recovery key` (raw/mnemonic), plaintext TOTP secrets,
**`bmk`** (the biometric wrap — device-local OS-keystore; no column in the server schema → a new device re-enrolls).
The login password ≠ the master password; neither derives the other.

**Format:** locally the `EncryptedBlob` nonce+ciphertext are TOGETHER; on the server (`key_attributes`) they are SEPARATE bytea columns.
They are split/joined with `ByteaCodec` (`\x`+hex, a single point). On restore the blob is `version = supportedVersion`.

**Server-wins:** upload happens only when NO record exists on the server (the initial backfill insert). Existing attrs are NOT OVERWRITTEN →
a `changePassword` on one device does not update the server in Patch 2 (multi-device consistency is Patch 3 LWW).
On restore the server wins (a new device pulls). A network error ≠ 0-row: if the network drops → `restoreFailed` (it does not fall back to setup,
no double-vault); only on a real 0-row does it go to setup.

## 13. Encrypted token sync + changePassword UPDATE (Phase 3 Patch 3)

**Goal:** sync the encrypted TOTP tokens across multiple devices — WITHOUT WEAKENING E2E.

**What goes to the server (all already opaque):** `ciphertext` + `nonce` — the `OtpAccount` JSON encrypted with masterKey +
XChaCha20-Poly1305 IETF; **AAD `token|1|<id>`** (each token is bound to its own id; a blob
cannot be decrypted under another id). Plus `version` + `deleted` (the soft-delete flag). **`updated_at`/`created_at`
are NOT SENT from the client** — a server trigger writes them with `now()` (LWW clock consistency).

**What NEVER goes to the server:** plaintext TOTP secrets, `masterKey`, `KEK`, `recovery key`. The sync layer
(`RawTokenStore`/`TokenSyncService`) NEVER SEES the masterKey — it reads/writes the opaque ciphertext without opening it. Tokens are
encrypted with the masterKey; the masterKey is wrapped in `key_attributes` → **token sync NECESSARILY runs AFTER key_attributes
restore + unlock** (a crypto dependency chain; a new device asks for the password first, then pulls tokens).

**Format:** locally the `EncryptedBlob` nonce+ciphertext are TOGETHER; on the server (`tokens`) they are SEPARATE bytea columns.
They are split/joined with `ByteaCodec` (`\x`+hex, a single point). On restore the blob is decrypted in the same AAD context
(same masterKey + same id → decrypts; `key_attributes` is identical across devices).

**Arrival-order LWW (conflict):** the server `updated_at` is the only valid ordering (it is NEVER compared against the client epoch-ms).
Each local record holds the last reconciled server cursor (`sv`). Whatever REACHES the server last wins;
in a conflict one device's change can be silently lost — a deliberate simplification for Phase 3 (no notification
to the user). The merge is id-based + idempotent.

**Soft-delete:** delete = `deleted=true` (no hard DELETE — there is no policy/grant on the server). The local tombstone preserves the last
known blob (the server already has it; it must carry a valid `EncryptedBlob`), it is pushed, and the other device hides it.

**Realtime = trigger only:** supabase-flutter Realtime double-encodes bytea (#1180) → the payload
is UNREADABLE; the change signal triggers a REST `pullSince`.

**changePassword (key_attributes UPDATE):** `KeyManager.changePassword` **does NOT CHANGE the masterKey** — it only
produces a new `kdf_salt/ops/mem` + new KEK + new `encrypted_master_key` (`recovery_encrypted_master_key`
is left untouched). → **tokens are not re-encrypted** (orthogonal to sync). The `key_attributes` row on the server is
UPDATEd (LWW `updated_at`) → a fresh-restore on a new device pulls the new password wrap. On a network error →
the `attrs_dirty_v1` marker stays SET → the next unlock's dirty-replay retries. In a conflict the last-to-arrive
wrap wins — **no data loss** (the losing device keeps working with its local attrs; since the recovery wrap is
unchanged, the recovery key works with either password).

## 14. devices + public-read tables (Phase 3 Patch 4) — DOES NOT TOUCH E2E

Patch 4 adds three identity/NON-sync capabilities and **does NOT touch the crypto model AT ALL** (NO new routine; none of
these tables carry a secret/masterKey/encrypted-data).

**What goes to `devices`:** a random `device_id` (`uuid v4`) + an optional `name`/`last_seen`. **NEVER a hardware identifier,
IP, location, or telemetry.** `device_id` lives in GLOBAL secure storage (uid-independent; all accounts on the same device share the
same id). It changes on reinstall (not a persistent hardware id — intentional, privacy-friendly).

**⚠️ Cross-account correlation TRADEOFF (ACCEPTED):** because `device_id` is global, if more than one Supabase account is used on the
same physical device, the backend/service_role can **correlate** those accounts via the shared `device_id`.
This was deliberately accepted for simplicity, for the sake of multi-device list consistency.
A more privacy-preserving alternative, if desired: a per-uid `device_id = HMAC(local_device_secret, uid)` (each account sees a different
id) — left as a future refinement.

**catalog_services / feature_flags / announcements:** PUBLIC read (anon+authenticated SELECT); the client ONLY
reads (no write grant). Contains no secret/crypto. **`catalog_services.logo_url` is IGNORED** — the `IssuerAvatar`
"NO runtime logo fetching (offline/privacy)" decision is preserved (no network image is downloaded; the catalog is only for issuer
NAME/slug canonicalization). The `token_sync_enabled` flag gates ONLY the token transfer; **`key_attributes`
(identity/recovery) is OUTSIDE the flag — it always works.**

## 15. Screen-capture protection (`SecureScreen` / `SecureScreenScope`)

Not part of the crypto model — a **shoulder-surfing / screenshot-malware** mitigation for the screens
where plaintext secrets are on glass. `lib/core/platform/secure_screen.dart` + a MethodChannel
(`dev.mustafakara.project_auth/secure_screen`).

| Platform | Mechanism | What it actually stops |
|---|---|---|
| Android | `WindowManager.LayoutParams.FLAG_SECURE` | screenshots, screen recording, recents preview |
| iOS | opaque overlay on resign-active | **only** the recents/background snapshot |
| test / desktop | silent no-op (`MissingPluginException` swallowed) | — |

**⚠️ iOS limitation (accepted, documented):** iOS has no FLAG_SECURE equivalent, so **screenshots and
screen recording are NOT blocked on iOS.** Only the app-switcher snapshot is hidden. Do not describe
this feature as "screenshot blocking" without that caveat.

### Protected screens and why

| Screen | Why |
|---|---|
| `VaultPage` | live OTP codes on screen |
| `UnlockPage` | master password typed |
| `SetupPasswordPage` | master password typed (+ strength meter) |
| `RecoveryUnlockPage` | 24 recovery words + a new master password |
| `RecoveryShowPage` | the recovery key is displayed |
| `RecoveryVerifyPage` | recovery words re-entered |
| `LoginPage` | Supabase account password typed |
| `RegisterPage` | Supabase account password typed (twice) |
| `ScanPage` | a QR **is** the secret; migration mode additionally renders an imported-token preview |
| `ImportPage` | the backup password is typed and the parsed issuer/account list is previewed |
| `ExportPage` | the backup password is typed (twice) |

Eleven screens — the authoritative list is `grep -rn "SecureScreenScope(" lib/`; keep this table in
step with it.

**Deliberately NOT protected:** `/auth-integrity` and the account screens that display nothing
secret (`/splash`, `/auth/confirm`, `/auth/link`, `/auth/restore-failed`); `/settings`, which shows
no secret of its own and is pushed **above a mounted `VaultPage`**, whose scope is still held — see
the router regression test in `test/core/router/secure_screen_router_test.dart`.

`/scan` was in that second list until Phase 5 Patch 2 for the same "pushed above the vault" reason.
It now carries its own scope: migration mode lists the tokens decoded out of a transfer QR, so the
screen must be protected on its own merits and not on its parent's — the parent is the wrong thing
to depend on the moment the screen can be reached any other way.

### Why the ref count lives in Dart

The native side does **not** count: Android `addFlags`/`clearFlags` and the iOS bool flag are
**last-caller-wins**. Sensitive screens nest (recovery pushed above the vault), so the naive
`initState`→enable / `dispose`→disable pattern turned protection **off too early** — the recovery
screen's `dispose` cleared FLAG_SECURE while the vault below was still visible and still showing live
codes, and the vault never re-enabled it because it was never disposed.

So the counter is kept in Dart: native `enable` fires **only on 0→1**, native `disable` **only on
1→0**.

Two exceptions guard against a *failed* native call:

- **`enable` rejected.** The `PlatformException` is swallowed (the screen must still work) but the
  protection is marked off, so the **next `acquire()` retries `enable` even without a 0→1 edge** —
  otherwise a single native failure would leave the protection silently off for the rest of the
  session, because that edge never comes back. That alone is not enough when only ONE sensitive
  screen is open, because then no further `acquire()` ever arrives, so a failed `enable` also
  schedules a **single delayed retry (500 ms)**, taken only while a holder is still around and the
  protection is still off. The retry itself does not re-arm one: the attempt is one-shot, never a
  loop.
- **`disable` rejected.** Native protection is then still ON, while `release()` had optimistically
  recorded it as off. The bookkeeping is rolled back to "on" so it does not drift away from the
  native state — otherwise the next `acquire()` would try to enable an already-enabled flag, and a
  protection that is actually up would be reported as down. `enable`/`disable` are not public — `acquire()`/`release()` are the only way in. An unmatched
extra `release()` is ignored so the counter can never go negative (a negative counter would swallow
the next `acquire()`'s 0→1 transition and leave protection off entirely). The native code
(`MainActivity.kt` / `AppDelegate.swift`) is unchanged by this design.

### How to use it

Wrap the **outermost** widget of the page's `build` in `SecureScreenScope` — acquire/release are then
bound to the widget lifecycle and protection stays on for the page's whole lifetime, even when another
route is pushed on top:

```dart
@override
Widget build(BuildContext context) => SecureScreenScope(
      child: Scaffold(/* ... */),
    );
```

**Never call enable/disable (or `acquire`/`release`) by hand** — manual pairing is exactly the bug the
scope exists to prevent.

## 16. Encrypted backup (Phase 5 Patch 1)

`BackupService` writes a **password-encrypted copy of the whole vault** to a file the user keeps
themselves. It introduces **no new crypto primitive**: the same Argon2id + XChaCha20-Poly1305 IETF
pair as the key hierarchy, through the same `CryptoService`.

The backup password is **independent of the master password**. The file must be openable on a device
that has no vault yet, so it cannot be tied to `KeyAttributes`; a backup is therefore NOT recoverable
with the master password or the recovery mnemonic. The export screen says so explicitly.

### 16.1 Envelope

```json
{
  "format": "projectauth-backup",
  "version": 1,
  "createdAt": "2026-09-02T10:11:12.000Z",
  "kdf": { "alg": "argon2id", "opslimit": 3, "memlimit": 268435456, "salt": "<b64 16B>" },
  "cipher": { "alg": "xchacha20poly1305-ietf", "nonce": "<b64 24B>" },
  "ciphertext": "<b64>"
}
```

The encrypted payload is `{"exportedAt": "...", "accounts": [OtpAccount.toJson(), ...]}` — the same
JSON the local store uses, so the stable `id` survives a restore (which is what lets the import
preview detect "already in your vault" by id rather than only by issuer/name).

Because the payload IS `OtpAccount.toJson()`, the optional `tags` of §9 ride along automatically:
a restore brings the user's labels back with their codes, and re-importing an exported backup is
tag-lossless. This needed **no envelope change** — `version` stays **1**, the AAD formula is
untouched, and a backup written before Patch 3 (no `tags` key anywhere) imports exactly as it did.
Tags are inside `ciphertext` like everything else, so the file leaks no label.

Everything outside `ciphertext` is public metadata. Nothing in the envelope reveals a secret, an
issuer or an account name.

### 16.2 Why the AAD is derived, never stored

```
AAD = "backup|<version>|<kdf.alg>|<opslimit>|<memlimit>|<base64 salt>|<cipher.alg>"   (UTF-8)
```

The KDF cost parameters live in the file, because a future build must be able to open an old backup.
That makes them **attacker-controlled**: anyone holding the file can rewrite `opslimit` to `1` and
brute-force the password far more cheaply. Feeding those exact fields into the AEAD's additional data
binds them to the ciphertext — a downgraded envelope simply fails its tag check, so the attacker
gains nothing and the honest user sees "wrong password or corrupted file".

For the same reason the envelope has **no `aad` field**: a stored AAD would be attacker-controlled
too and would defeat the whole construction. It is recomputed from the envelope on every read.
The salt is re-encoded from its decoded bytes (`base64Encode`), so a non-canonical encoding in the
file cannot produce a different AAD for identical salt bytes.

**Why `createdAt` is deliberately NOT in the AAD.** The AAD binds exactly the fields that change how
the ciphertext is opened — KDF algorithm, cost, salt, cipher algorithm. `createdAt` changes none of
them: rewriting it cannot downgrade the KDF, redirect decryption or reveal anything, so binding it
would buy no security. It would cost something, though: an ISO-8601 timestamp has several equally
valid spellings (`….000Z` vs `…+00:00`, with or without fractional seconds), so any tool that
re-serialised the envelope would produce a different AAD for the same instant and turn a perfectly
good backup into "wrong password or corrupted file". Accepted consequence: an attacker holding the
file can relabel its creation date undetected. `createdAt` is a human-readable label, and it is
documented here as one — nothing in the import path trusts it.

### 16.3 Strict validation before sodium

Same doctrine as §8 — the envelope is fully validated before a key is derived, so a malformed file
reports a format error instead of masquerading as a wrong password (and costs no Argon2id work):

| Field | Rule |
|------|-------|
| `format` | exactly `projectauth-backup` |
| `version` | `1..supportedVersion`; greater → `UnsupportedBackupVersionException` |
| `createdAt` | a parseable ISO-8601 timestamp |
| `kdf.alg` | exactly `argon2id` |
| `kdf.opslimit` | `1..10` |
| `kdf.memlimit` | `8 MiB .. 512 MiB` |
| `kdf.salt` | exactly `16` bytes (`crypto_pwhash_SALTBYTES`) |
| `cipher.alg` | exactly `xchacha20poly1305-ietf` |
| `cipher.nonce` | exactly `24` bytes (reuses `EncryptedBlob`) |
| `ciphertext` | at least `16` bytes — the Poly1305 tag (reuses `EncryptedBlob`) |

The bounds are two-sided on purpose: the lower bound blocks a cost downgrade even before the AAD
check, and the upper bound blocks a denial-of-service file that would ask sodium for an absurd
allocation. A fractional `num` is rejected rather than truncated, exactly as in §8.

Wrong password and tampered bytes are **indistinguishable by design** (that is what an AEAD is), so
both surface as the single `WrongBackupPasswordException`.

### 16.4 Password policy

`KeyManager.enforcePolicy` is the single source of both the thresholds and the Turkish messages
(§7): `KeyManager._enforcePasswordPolicy` now delegates to it, and `BackupService.export` calls it
directly. A weak backup password is refused **before** any Argon2id work.

### 16.5 Hygiene and limits

- The derived KEK is disposed in a `finally`, and the plaintext byte buffer is zero-filled on both
  the export and the import path.
- **Limit (accepted):** the intermediate `String` produced by `jsonEncode`/`utf8.decode` cannot be
  wiped — Dart offers no way to pin or clear a `String`. The window is short and the buffer we can
  reach is cleared; a heap dump of a live process remains outside this threat model.
- **Limit (accepted): the isolate copy.** `ImportService.preview` runs parse+dedupe inside
  `Isolate.run` so a large file cannot jank the UI. Isolates do not share memory, so the file text
  goes in as a **copy** and the parsed `OtpAccount`s (secrets included) come back as another one.
  Both copies live on a heap this code cannot reach at all — the worker isolate's heap is gone when
  `Isolate.run` returns, but only when the GC gets round to it. Same class of exposure as the
  `String` above, accepted for the same reason; nothing about it is made worse by the isolate, which
  is why the responsiveness win is taken.
- **iOS `saveFile` leaves a copy behind.** file_picker 11.0.3 implemented the iOS save by writing the
  bytes into the app's `NSDocumentDirectory/<fileName>` and exporting *that* through
  `UIDocumentPickerViewController`; neither the pick callback nor the cancel callback removed it,
  and `clearTemporaryFiles()` only walks `NSTemporaryDirectory()`, so it never saw this file. The
  app's Documents directory is part of the iCloud/iTunes device backup, so an encrypted vault backup
  the user thought they had put on a USB stick would also silently ride along to iCloud.
  `FilePickerDocumentPort.saveJson` therefore shreds it in a `finally`: zero-fill in place (opened
  `writeOnlyAppend` so the bytes are overwritten rather than truncated away), then unlink. It is
  best effort and every failure is swallowed — housekeeping must not turn a finished export into a
  user-facing error, and the file is encrypted regardless. No-op off iOS: Android writes through the
  SAF stream and desktop writes straight to the chosen path.
  **Status after the file_picker 12 upgrade (2026-09-02):** re-read from the source
  (`file_picker_darwin` 1.0.4, `IOSFilePickerHandler.swift` → `saveFile(_:)`), the staging file is now
  built from `NSTemporaryDirectory()`, not Documents. It is still never deleted after the export, but
  `NSTemporaryDirectory()` is excluded from device backups and reclaimed by the OS, and
  `clearTemporaryFiles()` does reach it — so the leak this shredder was written for is gone upstream.
  The shredder was **kept rather than reduced to a no-op**: it costs one `exists()` on a directory
  that should now hold no such file, and it is the only thing that would catch the destination moving
  back to a backed-up location in a future release.
  **Info.plist constraint that comes with this:** `UIFileSharingEnabled` and
  `LSSupportsOpeningDocumentsInPlace` must stay OUT of `ios/Runner/Info.plist`. Either one makes the
  app's own Documents directory visible in Files, at which point the user can pick it as the export
  destination — and the shredder would then be deleting the file the user just saved. The code does
  guard against that (it compares the chosen path against the leftover path and backs off), but the
  guard is a second line: do not add those keys without revisiting `_shredIosSaveLeftover`.
- **The picked-image copy is shredded, and the ORDER of the two cleanups matters (Phase 5 Patch 3).**
  "Görüntüden oku" (`ScanPage`) hands the system picker's cached copy of an image to the platform QR
  decoder. That copy is a plaintext **picture of a live TOTP seed** sitting in the app cache, a
  directory the OS reclaims on its own schedule — possibly never. `ScanPage._pickFromImage` therefore
  cleans up in a `finally`, in exactly this order:
  1. `FilePickerDocumentPort.shredCachedCopy(path)` — zero-fill in place (opened `writeOnlyAppend`, so
     the bytes are overwritten rather than truncated away) **then** unlink. It is deliberately
     **synchronous**: it has to finish before step 2 touches the same file, and before a screen torn
     down mid-flow could abandon a pending `await`.
  2. `DocumentPort.clearPickerCache()` — the plugin's general cache sweep, which catches anything the
     targeted shred did not (an earlier pick, a copy under a name we were never told).
  Reversed, step 2 would **unlink the file without overwriting it** and step 1 would find nothing —
  leaving the QR's pixels recoverable on the block device. Both steps are best effort and swallow
  every failure (housekeeping must not turn a completed import into an error).
  **The user's original image is never touched.** The plugin hands over the sandbox copy's path only;
  nothing in the app writes to or deletes anything in the photo library. On iOS the pick goes through
  `file_picker_darwin`'s PHPicker, so the app gets one photo *without* holding library access — no
  permission prompt appears. `ios/Runner/Info.plist` declares `NSPhotoLibraryUsageDescription` all the
  same: App Review looks for it in an app that picks images, and it keeps the prompt from being
  string-less should the plugin ever fall back to the older picker.
  The image is also never re-encoded (`compressionQuality` stays 0) and never read into Dart memory —
  the decoder takes a **path**, so a multi-megapixel photo is not copied into a `Uint8List`, and the
  16 MiB ceiling (`QrImageLimits.maxBytes`) is checked against the size the picker reports *before*
  anything is read. Decoded strings are returned to the caller and nothing else: never logged, never
  cached, never placed on the clipboard, and the two decoder exceptions deliberately carry no platform
  message (a plugin error string can quote a file name or file content).
- A malformed record inside a decrypted payload is **skipped, not fatal** — one bad row must never
  cost the user the rest of their tokens. `import()` returns the usable accounts; `importDetailed()`
  additionally returns a `SkippedEntry` per dropped record so the preview can report the count. Skip
  labels are `"Issuer (account)"` at most and **never** contain a secret.
- Restoring an old backup can resurrect a token the user has since deleted: local deletion is a
  tombstone (§9), and a restore re-adds the id. This is intended — a backup is a point-in-time copy.

### 16.6 Tests

Host (`test/features/import_export/`): envelope JSON + AAD derivation + strict validation;
`BackupService` export/import against the shared `test/support/fake_crypto.dart`, which binds both
the key (derived from password + salt) and the AAD and carries a hash-based stand-in for the
Poly1305 tag, so wrong-password, tamper and parameter-downgrade behaviour is reproducible on the VM.

Integration (`integration_test/backup_service_test.dart`, real libsodium, per §10): round-trip
including the stable `id`, wrong password, tampered ciphertext, tampered nonce, and — the reason the
AAD exists — an `opslimit`/`memlimit` downgrade that stays inside the accepted range and still fails
to decrypt.

## 17. System file-picker lock exemption (Phase 5 Patch 1)

**This is a deliberate concession in the threat model, not a neutral implementation detail.** It is
documented here so it is reviewed as such.

The system file picker (Android SAF, iOS `UIDocumentPicker`) runs in a **separate process**. While it
is on screen our app receives `paused`, and the normal lifecycle rule (§ `VaultLockCubit.onAppBackgrounded`)
wipes the master key from memory and tears the unlocked subtree down. Applied literally, choosing a
file would therefore always lock the vault before the import/export flow could finish — the feature
would be impossible.

The flows that open it are consequently wrapped in a
`VaultLockCubit.beginSystemFileFlow()` / `endSystemFileFlow()` pair. There are **three** of them:

| Flow | Screen | Picker |
|---|---|---|
| Import a vault file | `ImportPage._pickFile` | document picker (`DocumentPort.pickJson`) |
| Export an encrypted backup | `ExportPage` | save dialog (`DocumentPort.saveJson`) |
| Read a QR from a saved image (Phase 5 Patch 3) | `ScanPage._pickFromImage` | image picker (`DocumentPort.pickImage`) |

The third one follows the identical discipline: the `begin` is paired with an `end` in an **inner
`finally` around the pick itself** — the exemption covers the picker round-trip and nothing more, so
the decode, the shred and the preview all run with the ordinary lock rules back in force. Because
`ScanPage` can be torn down while the picker is still up (back gesture, router redirect), `dispose`
additionally closes an exemption that is still active, exactly as the import/export screens do.

The pair, in all three cases:

- the exemption skips the background lock **including `paused`**, not only `inactive` (which is all
  the pre-existing biometric-prompt exemption covers);
- it is bounded by a **2-minute budget**, which a further `beginSystemFileFlow()` **renews** — the
  import flow legitimately opens the picker more than once (pick a file, then pick another), and a
  user browsing a cloud provider's folders can honestly spend more than one budget in there;
- renewal is capped in absolute time: the first `begin` of a run starts a clock, and once
  `VaultLockCubit.systemFileFlowMaxTotal` (**10 minutes**) has elapsed since it, further renewals are
  **refused** — the running deadline is left alone, so the flow still expires on its own schedule and
  `endSystemFileFlow()`/`main.dart` still lock. Without the cap, a chain of renewals would quietly
  turn a 2-minute concession into an unbounded one. `endSystemFileFlow()` clears the clock, so the
  next flow starts fresh;
- every call site closes it in a **`finally`**, and the import/export screens additionally close it
  from `State.dispose` (a screen torn down while the picker is up — router redirect, back gesture —
  would otherwise leave it open), so cancel, throw and screen dispose all end it;
- `endSystemFileFlow()` itself **locks immediately** when the budget has already lapsed, so an
  over-long picker is caught even when the picker result arrives before the `resumed` lifecycle
  event;
- on resume `main.dart` repeats the check via `systemFileFlowExpired` and **locks immediately** when
  the budget was exceeded, so an app parked in the background does not stay open indefinitely.

**What the exemption does NOT cover:** `onAuthSignedOut` (the identity gate closing) and an
interactive `lock()` still take effect during a flow.

**What is actually given up:** during a window of at most 2 minutes — or, across a renewed chain, at
most 10 — an attacker with physical access
to an unlocked-but-backgrounded device can return to a still-unlocked vault, where the ordinary rule
would have locked it on the first `paused`. The master key stays resident in memory for that window.
The budget, the `finally` discipline and the resume check bound the exposure; they do not remove it.

Covered by `test/features/auth/vault_lock_cubit_test.dart` (exemption honoured, budget expiry,
renewal, the absolute cap and its reset by `endSystemFileFlow`, the `finally` pairing) and by the
import/export widget tests plus `test/features/scan/scan_page_image_test.dart`, which assert the
begin/end call counts (exactly one each, on the cancel, success and failure paths alike).
