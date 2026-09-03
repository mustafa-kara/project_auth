# Crypto Design — E2E Vault (Phase 2)

> Scope (Patches 1–5 implemented): package decision, primitives, key hierarchy,
> AAD scheme, BIP39 recovery, password/normalization decision, validation bounds,
> encrypted vault store + migration; **Patch 4: setup/unlock/recovery UI + session
> lock (`VaultLockCubit`, lifecycle lock) + `KeyAttributesStore` + reset + UI
> redesign** (the design system is kept local); **Patch 5: biometric unlock
> shortcut (3rd wrap + OS-keystore access control)** — see §11. Phase 3 sync envelopes: §12–14.
> Screen-capture protection (`SecureScreenScope`, ref-counted): §15.
> **Phase 7 — key-lifecycle & memory-wiping review (2026-09-02):** the secure-storage options, the
> sign-out rule and the plaintext-drop rule are folded into §3, §9.1–§9.3 and §11; the sensitive
> clipboard is in §16.5; **§18 states, in one place, what "wiping" can and cannot mean in Dart.**

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
  the UI. Inside the isolate the password is converted to an `Int8List`, then zero-filled after the operation,
  and the derived KEK comes back as a **native handle** (`copy().detach()`), so the key bytes never round-trip
  through the Dart heap.
  **Half the story, said plainly (Phase 7 review):** `Isolate.run` captures the password *`String`*, so it is
  **deep-copied** into the worker isolate's heap — and a Dart `String` cannot be zeroed by anyone. The
  `Int8List` wipe clears the copy we can reach; the copied `String` is freed unscrubbed when the worker shuts
  down. Same class of exposure as every other password/secret `String` in the app — see §18.

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

**Key lifetime rules (Phase 7 key-lifecycle review, 2026-09-02).** Three invariants that used to be
implicit are now enforced in code:

- **The key's disposal is also the plaintext's disposal.** `VaultLockCubit._disposeKey()` runs every
  registered *plaintext holder* **synchronously, before** `_masterKey.dispose()`. Holders register through
  `registerPlaintextHolder(void Function() wipe)`, which returns an unregister callback: today the vault
  shell registers `VaultCubit.wipe()` (which clears `VaultState` and calls
  `EncryptedVaultRepository.forgetPlaintext()`) and `ImportPage` registers the drop of its raw file text.
  A holder that throws cannot stop the other holders or the key's disposal.
  **Why it had to be synchronous:** `lock(immediate: true)` disposes the key without waiting for a frame
  precisely because a backgrounded app is not guaranteed one — but dropping the decrypted secrets still
  depended on that frame (`emit` → router redirect → subtree teardown → `VaultCubit.close()`). The key went,
  and every `OtpAccount.secret` it existed to protect stayed. Subtree teardown is unchanged; it is now
  cleanup rather than the mechanism.
  **What this achieves, stated honestly: unrooting, not erasing.** Dart cannot zero a `String`, and the GC
  does not scrub what it reclaims. The gain is that the secrets stop being reachable from the object graph —
  the difference between "walk the graph from the cubit" and "trawl freed heap". Do not call it wiping (§18).
- **Every path out of `signedIn` closes the E2E gate**, not just the sign-out button. The identity gate is
  *above* the E2E gate (ARCHITECTURE §7), so `onAuthSignedOut()` now fires on the `authStateChanges` stream's
  `signedOut` (gotrue emits that on refresh-token failure, server-side revocation, expiry and a global
  sign-out from another device — the paths a **stolen device** actually takes), on
  `cancelPendingConfirmation()`, on `bootstrap()`'s non-`signedIn` branches, and once more at the boundary in
  `main.dart._onSession` (the callback is idempotent, so the double call is harmless). Before this, a
  non-interactive sign-out left the master key resident for as long as the user sat on `/auth/login`, and
  signing back in as the **same uid** reused the still-`unlocked` cubit — i.e. the *account* password alone
  re-opened the plaintext vault, inverting the premise that the two passwords do not derive each other.
- **`resetVault()` goes through the state machine.** When the vault is `unlocked` it now calls
  `lock(immediate: true)` first (which disposes the key *and* runs the plaintext holders) instead of reaching
  past the machine to `_disposeKey()` and then `await`ing the remote tombstone, `biometric.disable()` and
  `_deleteKeys()` with the unlocked subtree still mounted around a freed `KeyHandle`. That window was a latent
  use-after-free (`sodium_mprotect_readonly` on freed memory), unreachable through today's only in-vault
  caller but exactly what the `locking` → dispose ordering exists to prevent.

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

**Encoding (Phase 7 review, P3-6) — the AAD strings themselves are UNCHANGED.** `KeyManager._aad` and
`EncryptedVaultRepository._aad` build the bytes with **`utf8.encode`**, not `String.codeUnits`. `codeUnits`
truncates UTF-16 units to 8 bits, so a single non-ASCII character would have produced a silently *wrong*
AAD; the column header above reads "UTF-8/codeUnits" because for these strings the two are byte-identical,
and that is now **pinned by a test** (`test/features/auth/aad_encoding_test.dart`) instead of assumed. Every
AAD this app produces is ASCII: the three `KeyManager` constants are literals, and a token AAD is the ASCII
prefix plus a uuid v4 id (locally only `OtpAccount`'s `Uuid().v4()` mints ids — the import parsers
deliberately mint fresh ones — and `tokens.id` is a Postgres `uuid` column, so a non-ASCII id cannot arrive
through sync either). **No blob, no record `v`, no envelope changed**; existing vaults and backups open
exactly as before.

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

### 9.1 Shared secure-storage options (Phase 7 review, P1-2/P3-1)

Every vault store — `KeyAttributesStore`, `VaultMigration`, `EncryptedVaultRepository`, the marker stores —
shares one `FlutterSecureStorage` instance, and its options are now **passed explicitly**, because two plugin
defaults were wrong for irreplaceable key material. The single definition is `secureStorageOptions()` in
`lib/core/config/secure_gotrue_storage.dart`; the DI registration and the Supabase session adapters (§9.2)
both call it so the two sides cannot drift apart against the same Keystore.

| Option | Value | Why the default was wrong |
|---|---|---|
| `AndroidOptions.resetOnError` | **`false`** (plugin default `true`) | fss 10.x deletes the entry and retries on **any** read error, so the second read returns **`null` with no exception** — the "silent null = uninitialized" case `KeyAttributesStore` exists to prevent. `bootstrap()` would see `attrs == null`, show **setup**, and `commitSetup` would overwrite the only two wraps of the master key. Recovery mnemonic included: gone. |
| `AndroidOptions.migrateWithBackup` | **`true`** (default `false`) | makes the v9→v10 algorithm migration crash-recoverable; a crash mid-migration otherwise lands in the `resetOnError` branch above. |
| `IOSOptions.accessibility` | **`unlocked_this_device`** (default `unlocked`) | the default is not a `ThisDeviceOnly` variant, so the item rides an encrypted iTunes/Finder backup onto a **new device**. The documented new-device story is a server restore (§12), not a keychain migration. Accessibility applies at **write** time, so existing items migrate on their next write — no user is stranded. |

Two consequences follow, and both are implemented:

- **A storage failure is now a screen, never a silent setup.** With `resetOnError: false` a Keystore/Keychain
  failure surfaces as a `PlatformException`. `VaultLockCubit.bootstrap()` maps it to
  `keyAttributesCorrupted` exactly as it already mapped `FormatException` → `/auth-integrity`, which offers
  **"Yeniden dene"** (`retryBootstrap`) and, as a last resort, reset. Unmapped, the exception would have
  escaped the `bootstrap` future as an unhandled async error and left the state at `uninitialized` — i.e. the
  router would still have shown setup, which is precisely the outcome being defended against.
- **The ciphertext must not travel without its wrapping key.** `android:allowBackup="false"` +
  `fullBackupContent="false"` reliably disable only **cloud** backup; per the Android manifest documentation,
  apps targeting API 31+ cannot always disable **device-to-device** migration. A D2D transfer would move the
  plugin's SharedPreferences *ciphertext* to a new phone while the wrapping key stays in the Android Keystore
  by construction → first read fails to unwrap. `android/app/src/main/res/xml/data_extraction_rules.xml`
  (referenced from the manifest as `android:dataExtractionRules`) therefore excludes the plugin's prefs files
  from **both** `<cloud-backup>` and `<device-transfer>` — the data, key and config prefs for the default
  namespace *and* for the separate `vault_biometric` namespace (§11). The file names come from the installed
  plugin's Java source and are cited there; **re-verify them on every plugin upgrade**, because a path that no
  longer matches fails silently, which means no protection at all.

### 9.2 The Supabase session and the PKCE verifier live in the same secure storage (P2-5)

`supabase_flutter` defaults both `localStorage` and `pkceAsyncStorage` to **SharedPreferences**, so the
long-lived refresh token and the PKCE code verifier sat in a plain XML/plist file while everything else in the
app was behind Keychain/Keystore. `SecureLocalStorage` and `SecureGotrueAsyncStorage`
(`lib/core/config/secure_gotrue_storage.dart`) replace them, built on `FlutterSecureStorage` with the §9.1
options. They are constructed in `main()` **before** `configureDependencies()` — `Supabase.initialize` runs
first — so they hold their own storage instance rather than the locator's; the shared options factory is what
keeps the two identical.

- **The E2E boundary was never at risk** — a stolen refresh token yields only ciphertext (§12/§13). What it
  did yield is the Argon2id-wrapped master key for an offline attack at whatever the user's master-password
  strength happens to be, and **write** access: an attacker can tombstone every token row, and sync replicates
  that faithfully to the user's real devices. And per §9.1, an Android D2D transfer moved this file
  **readably** — so the one credential surviving a device migration intact was the weakest-stored one.
- **One-time migration, so nobody is signed out by the upgrade.** The session key is regenerated with
  supabase_flutter's own formula (`sb-<host-first-label>-auth-token`) and the verifier migrates under whatever
  key gotrue asks for, so an in-flight email confirmation survives. The prefs copy is deleted **only after**
  the secure write succeeds → a crash mid-migration retries on the next launch instead of losing the session.
- **The error policy is deliberately the opposite of §9.1's.** Key attributes are irreplaceable, so a storage
  failure there must surface. A session is a replaceable **cache**: the user logs in again. Read/write
  failures here are therefore swallowed and read as **"signed out"** — letting the exception escape
  `Supabase.initialize` would be a black screen at boot with no recovery path, and losing a session is not
  losing data.

### 9.3 Zero-filling in the token store (P2-6)

`EncryptedVaultRepository` was the only crypto call site not zero-filling its plaintext buffers, while it is
the hottest one (every load, every save). Both the decrypt output on load and the encrypt input on save are
now cleared in a `try/finally`, mirroring `BackupService.importDetailed` and the §3/§16.5 rule.
**Limit (accepted):** the `String` that `utf8.decode` produces and the `secret` inside the resulting
`OtpAccount` remain unwipeable — this clears one of the two copies, which is what is actually achievable
(§18). Do it for consistency with the rest of the codebase, not because it closes the hole.

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
**The flag is cleared in a single `finally` (Phase 7 review, P2-2)** — it used to be reset inside each of the
five typed `catch` clauses and on the success path, so anything `retrieve()` threw *outside* those types left
it stuck `true` for the rest of the cubit's life. That is reachable: `MissingPluginException` does not extend
`PlatformException`, so `BiometricServiceImpl` never maps it, and `UnlockPage` catches nothing. From then on
`onAppBackgrounded(paused: false)` returned early and `inactive` — the app switcher, the notification shade,
an incoming call — **no longer locked an unlocked vault** (`paused` still did, so it narrowed the protection
rather than removing it). The typed failures are handled *after* the `finally`, so the `BiometricKeyMissing`
branch's `await` no longer runs with the flag still set. Never add another assignment to that flag.

**Storage options:** the biometric key deliberately does **not** use the shared instance of §9.1 — it has its
own namespace and OS-gated options, and there the plugin's auto-delete on error is *acceptable*, because
`BiometricKeyMissing` is a handled, recoverable state (fall back to the password, clear `bmk`, re-enrol). Its
prefs files are nevertheless excluded from cloud backup and device transfer alongside the vault's (§9.1).

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
  reach is cleared; a heap dump of a live process remains outside this threat model. **This is not special to
  the backup path** — it is equally true of the master password, the 24 mnemonic words and every
  `OtpAccount.secret`; the full list is §18.
- **The clipboard is hardened where the OS allows it, and not overstated where it does not (Phase 7 review,
  P2-4).** `Clipboard.setData` writes to the bare system pasteboard: on iOS that is `UIPasteboard.general`
  with no options, so the item joins **Universal Clipboard** and a copied recovery key can travel over the air
  to every other device on the same iCloud account within seconds; on Android the primary clip is rendered in
  the Android 13+ clipboard preview bubble because Flutter never sets `ClipDescription.EXTRA_IS_SENSITIVE`.
  `SensitiveClipboard` (`lib/core/platform/sensitive_clipboard.dart`) is a small platform channel next to
  `SecureScreen`'s:
  - **iOS** — `setItems(_:options:)` with `.localOnly` (the item stays on this device) and `.expirationDate`
    (the OS drops it itself, which **still holds when the process is killed** and the Dart timer never runs).
  - **Android** — `ClipData` plus, gated on API 33+, `description.extras = PersistableBundle{EXTRA_IS_SENSITIVE:
    true}` so the preview does not render the value. Android has **no OS-level clipboard expiry**, so the
    expiry argument is ignored there.
  - When the channel is absent (host VM test, web, desktop) — or the native side rejects the call — it falls
    back to `Clipboard.setData`, so copying never regresses on any platform. Silently copying *nothing* would
    be a worse surprise than copying unhardened.
  The **existing conditional Dart timers are unchanged and remain the primary cleanup** (60 s for the recovery
  mnemonic, 30 s for an OTP code); they are conditional so they never clobber something the user copied
  meanwhile, which an OS expiry cannot distinguish. The OTP card therefore asks the OS for a *longer* 45 s
  expiry — the backstop must not win the ordinary race. The recovery snackbar now says the copy is
  device-local and expires, instead of implying more containment than a 60 s timer can deliver.
  **Scope, honestly:** this does not make the clipboard safe. The foreground app can still read the primary
  clip on Android, pasting is still free on iOS, and the pasteboard's own storage is outside the process
  ("OS copies", §18). What is bought is closing the **off-device** path and the **preview** leak, plus an
  expiry that survives a process kill.
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

**What the exemption does NOT cover:** `onAuthSignedOut` (the identity gate closing — which, since the
Phase 7 review, means **every** transition out of `signedIn`, not only the sign-out button; §3) and an
interactive `lock()` still take effect during a flow. Anything added later that locks on its own — a
foreground idle auto-lock is the open PLAN item — must respect this exemption for the same reason it exists:
the picker runs in another process, so the app is `paused` while the user is legitimately choosing a file.

**What is actually given up:** during a window of at most 2 minutes — or, across a renewed chain, at
most 10 — an attacker with physical access
to an unlocked-but-backgrounded device can return to a still-unlocked vault, where the ordinary rule
would have locked it on the first `paused`. The master key stays resident in memory for that window.
The budget, the `finally` discipline and the resume check bound the exposure; they do not remove it.

Covered by `test/features/auth/vault_lock_cubit_test.dart` (exemption honoured, budget expiry,
renewal, the absolute cap and its reset by `endSystemFileFlow`, the `finally` pairing) and by the
import/export widget tests plus `test/features/scan/scan_page_image_test.dart`, which assert the
begin/end call counts (exactly one each, on the cancel, success and failure paths alike).

## 18. Dart/Flutter limits — what "wiping" can and cannot mean here

Written after the Phase 7 key-lifecycle review and kept separate from the fixable items above **so the two are
never confused**. Everything in §3, §9.3 and §16.5 that talks about clearing memory is about *shrinking and
unrooting* the resident copies of a secret. None of it erases them. Treating it as more than that would be
theatre.

1. **A `String` cannot be wiped or pinned.** The master password (the `TextEditingController.text` and every
   substring the framework makes of it), the backup password, the 24 mnemonic words, each `OtpAccount.secret`,
   and the JSON produced by `jsonEncode`/`utf8.decode` are all immutable heap objects with **no zeroing API**.
   `controller.clear()` drops a *reference*; it does not erase the characters. Every `fillRange(0)` in this
   codebase operates on a `Uint8List`/`Int8List` — never on the `String` beside it.
2. **The GC copies, and does not scrub.** Dart's generational collector relocates live objects during
   scavenges, so one secret may exist at several addresses at once, and reclaimed memory is not zeroed. Even a
   perfectly disciplined `fillRange` only clears the copy you are holding.
3. **The isolate hop deep-copies the password.** `SodiumCryptoService.deriveKek` passes a closure to
   `Isolate.run` that captures the password `String`, so it is copied into the worker's heap; the `Int8List`
   derived from it *inside* the isolate is correctly zeroed, but the copied `String` cannot be, and the
   worker's heap is freed without scrubbing when the isolate shuts down (§2). The same applies to
   `ImportService.preview` (§16.5).
4. **Platform-channel values are `String`s.** `flutter_secure_storage`'s API is `String`-only, so the
   biometric key transits as base64 through Dart, the channel codec and the platform side with no wipeable
   representation at any hop. Unavoidable short of a custom FFI keystore binding.
5. **No control over OS-level copies.** Keyboard/IME buffers, the pasteboard's own storage, swap, hibernation
   images and OS crash dumps are all outside the process. `enableSuggestions: false`/`autocorrect: false`,
   `FLAG_SECURE` (§15) and the sensitive-clipboard flags (§16.5) narrow this; they do not close it.
6. **iOS cannot block screenshots** — see §15, where it is already documented and caveated.
7. **A heap dump of the live process defeats all of the above**, and is explicitly outside the threat model
   (§16.5).

**What *is* achieved, and is worth having.** The master key itself is genuinely hardened: `SecureKeyFFI`
allocates through `sodium_malloc` (guard pages + canary + `mlock`), holds `sodium_mprotect_noaccess` at rest,
unlocks only inside `runUnlockedNative`, and `sodium_free`s — which zeroes — on dispose; `runIsolated` returns
the derived KEK as a native handle, so key bytes never touch the Dart heap. Around that, the disciplines above
mean the *plaintext* secrets stop being **rooted** in the object graph the moment the key is disposed (§3),
exist in **fewer** copies (§9.3, and the OTP card decoding its Base32 seed once per card instead of once per
tick per card), and are never printed (`stringify => false` on both `OtpAccount` and `VaultLockState` — the
latter's props include the recovery mnemonic, which `equatable` would otherwise print in any assert-enabled
build: a widget-tree dump, an assertion message, a `bloc_test` failure in CI, DevTools).
