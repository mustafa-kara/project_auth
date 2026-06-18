# Crypto Design — E2E Vault (Phase 2)

> Scope (Patches 1–5 implemented): package decision, primitives, key hierarchy,
> AAD scheme, BIP39 recovery, password/normalization decision, validation bounds,
> encrypted vault store + migration; **Patch 4: setup/unlock/recovery UI + session
> lock (`VaultLockCubit`, lifecycle lock) + `KeyAttributesStore` + reset + UI
> redesign** (the design system is kept local); **Patch 5: biometric unlock
> shortcut (3rd wrap + OS-keystore access control)** — see §11.

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

Because `KeyManager` is a security boundary, a minimum rule is enforced here in addition to the
UI validator (`WeakPasswordException`):
- empty after trim → reject
- `< KeyManager.minPasswordLength` (8) → reject
- The policy check is trimmed, but **the actual KEK derivation uses the password verbatim**.

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
