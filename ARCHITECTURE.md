# Authenticator App — Architecture Document

> E2E-encrypted, multi-device synchronized TOTP/HOTP authenticator (similar to Ente Auth).
> Flutter (mobile) + Next.js (admin) + Supabase (backend).

---

## 1. Overview

| Decision | Choice |
|---|---|
| Core product | TOTP/HOTP/Steam authenticator |
| Platforms (Phase 1) | iOS + Android |
| State management | Bloc (mixed: simple → Cubit, complex/event-driven → Bloc) |
| Architecture | Feature-first + layered (data/domain/presentation) |
| Routing | go_router |
| Backend | Supabase (Auth + Postgres + Realtime + RLS) |
| Encryption | **E2E** (Ente model) — the server can never see the plaintext secret |
| Crypto lib | libsodium — `sodium ^3.4.6` + `sodium_libs ^3.4.6+4` (implemented in Phase 2; sodium 4.x requires Dart 3.11+, the project is on 3.10.7 → 3.x is a deliberate decision, see note + docs/CRYPTO.md) — XChaCha20-Poly1305 IETF (`crypto_aead_xchacha20poly1305_ietf_*`) + Argon2id (details in §2.4) |
| Key & recovery | Random master key; master password → KDF → wrapped with KEK; also wrapped with a recovery key (details in §2.2) |
| Sync | Real-time multi-device (Supabase Realtime) |
| Login | Phase 3: email/password · **Phase 4**: Google + Apple Sign-In (developer accounts required) |
| Admin panel | Next.js / React (cross-user reads: server-side direct Postgres + private aggregate fn · API/writes: secret key + `auth.admin` · admin-public tables via client) |
| Push | FCM (**Phase 4** — APNs certificate + Apple account required) |

> **Package versions to verify** (confirm with `flutter pub` and `npm` when starting setup/developer-account onboarding): `sodium`, `flutter_secure_storage`, `mobile_scanner`, `local_auth`, `supabase_flutter`, `go_router`, `flutter_bloc`. The choices below are valid as of January 2026, but check the latest versions when you begin setup.
>
> 🔐 **Crypto package decision (implemented in Phase 2, confirmed):** `sodium: ^3.4.6` +
> `sodium_libs: ^3.4.6+4`. `sodium 4.x` requires Dart SDK `^3.11.0`; this project is on Dart
> `3.10.7` (Flutter 3.38.6 stable) → **4.x IS UNRESOLVABLE**. Although `sodium_libs` appears
> "discontinued" on pub, it loads pre-built binaries and does NOT REQUIRE native-assets/experiment
> flags; the 3.x line works on stable Flutter (proven by integration tests).
> When we later upgrade to Dart 3.11+, the move to 4.x native-assets is a separate small migration.
> The XChaCha20-Poly1305 IETF + Argon2id algorithm decision does not change. Aligned with README/PLAN.
> Details: docs/CRYPTO.md.

---

## 2. Security Architecture (the most critical section)

### 2.1 Threat model
- **Party we do NOT trust:** the Supabase server / DB administrator / an attacker — even if they read the DB, they must not be able to decrypt the TOTP secrets.
- **Party we trust:** the user's device (secure enclave/keystore) and the master password held in the user's mind.
- **Conclusion:** every secret sent to the server must be **encrypted on the client side**. The server only sees opaque blobs.
- **Partially mitigated (2026-09-01, extended 2026-09-02):** an on-device **observer** — shoulder-surfing, screenshot
  malware, or a screen recorder — is a different threat from the server. Eleven screens are marked with
  `SecureScreenScope` → Android `FLAG_SECURE`: vault, unlock, setup_password, the three recovery screens
  (recovery_show / recovery_verify / recovery_unlock), login, register, scan, import and export. The authoritative
  list is `grep -rn "SecureScreenScope(" lib/`. **iOS has no equivalent**, so only the recents/background snapshot is
  hidden there. See [docs/CRYPTO.md §15](docs/CRYPTO.md).

### 2.2 Key hierarchy (Ente model)

```
Master Password (set by the user — SEPARATE from the login password)
        │  Argon2id (salt, opsLimit, memLimit stored in the DB)
        ▼
   KEK (Key Encryption Key) ── never leaves the device
        │
        ├─ encrypt ──► Master Key (randomly generated, the actual data key)
        │                   │
        │                   └─ The Master Key, wrapped with the KEK (encryptedMasterKey), is stored on the server
        │
        └─ Recovery Key (random 256-bit, shown to the user as 24 words/hex)
                 │
                 └─ The Master Key is ALSO wrapped with the Recovery Key (recoveryEncryptedMasterKey)
                    → if the password is forgotten, the master key can be recovered with the recovery key
```

**Flow:**
1. At registration: generate a random `masterKey`. The user enters a master password → Argon2id → `KEK`.
2. Encrypt `masterKey` separately with both the `KEK` and the `recoveryKey` → store both on the server.
3. Each TOTP secret is encrypted with a key derived from `masterKey` (XChaCha20-Poly1305) → ciphertext + nonce go to the server.
4. Password change: only the KEK-wrapping of `masterKey` is rewritten; none of the secrets are re-encrypted. (A major advantage.)
5. Forgotten password: `masterKey` is unwrapped with the recovery key, new password → new KEK → re-wrap.

### 2.3 On-device storage
> **IMPLEMENTED in Phase 2 Patch 5** — the fast-unlock plan in this section was realized exactly
> (iOS `biometryCurrentSet`+Secure Enclave, Android `setUserAuthenticationRequired`/
> `strongBiometricOnly`, `local_auth` as availability — not just a prompt, the real gate being
> the OS access-control on `flutter_secure_storage.read`). Details + threat model: [docs/CRYPTO.md §11](docs/CRYPTO.md).

- The `KEK` and the plaintext `masterKey` **are NOT kept in plaintext on disk.**
- During the session the `masterKey` is held in memory; it is cleared when the app goes to the background/lock.
- **Fast-unlock mechanism (clarification):** the master key is stored wrapped by an **access-controlled** key in the OS keystore:
  - iOS: Keychain item `kSecAttrAccessControl` + `.biometryCurrentSet` (backed by the Secure Enclave).
  - Android: a key in the Keystore with `setUserAuthenticationRequired(true)`; StrongBox is used when available.
  - Here `local_auth` only triggers the UI prompt; **the real security lies in the OS keystore access-control** (a "success" return from local_auth alone does not grant access to the key — the keystore itself holds the key behind biometrics).
  - `flutter_secure_storage` is used to store this wrapped blob; the access-control requirements are configured through the platform channel (a thin native bridge if needed).
- Fallback when biometrics fail/are absent: the user enters the master password → KEK → master key.
- **Master password policy** (single source of truth in `KeyManager`): minimum **12 characters** and at least
  **3 distinct character classes** (upper/lower/digit/symbol) — raised from "min 8" on 2026-06-19.
- **Android Auto Backup is disabled** (`allowBackup=false`, `fullBackupContent=false`): `flutter_secure_storage`'s
  `EncryptedSharedPreferences` must not be backed up (privacy + a new-device Keystore mismatch would corrupt the vault).

### 2.4 Encryption primitives
| Purpose | Primitive |
|---|---|
| Password → key | Argon2id (`crypto_pwhash`, alg = `crypto_pwhash_ALG_ARGON2ID13`) |
| Secret/data encryption | XChaCha20-Poly1305 IETF AEAD — `crypto_aead_xchacha20poly1305_ietf_encrypt/decrypt` |
| Key wrapping (key wrap) | Same AEAD family: `crypto_aead_xchacha20poly1305_ietf_*` |
| Recovery key encoding | BIP39-like word list or hex |

> **API clarification:** the correct libsodium family for XChaCha20-Poly1305 is `crypto_aead_xchacha20poly1305_ietf_*`. `crypto_secretbox` is **not used** — that is XSalsa20-Poly1305 (a different construction). For consistency, all encryption/wrapping is done through a single family (XChaCha20-Poly1305 IETF); thanks to the 192-bit nonce, generating random nonces is safe.

> **Critical rule:** No cryptographic routine is hand-written. Only libsodium is called. Nonces are randomly generated with `randombytes_buf` on every encryption and stored alongside the ciphertext.

---

## 3. Layered Architecture (MVVM + Clean)

```
Presentation (View)  ── Flutter widgets, UI only
        │  watch/read
Bloc/Cubit (ViewModel) ── state + UI logic, calls UseCases
        │
Domain (UseCase + Repository interface + Entity) ── pure Dart, framework-independent
        │
Data (Repository impl + DataSource + DTO) ── Supabase, secure storage, crypto
```

- The **View** never calls the Repository/Supabase directly; it only talks to the Bloc/Cubit.
- **Bloc/Cubit** = the ViewModel in MVVM. State is immutable — hand-written classes with `equatable` (**no `freezed` / no codegen**; the unused codegen packages were removed on 2026-09-01). The same rule decided the Google Authenticator importer: its
  `MigrationPayload` protobuf is decoded by a **hand-written wire reader** (`data/protobuf_wire.dart`) rather than
  by the `protobuf` package plus a `build_runner` step — and the hand-written reader is also the only one that can
  see proto3 **field presence**, which is what distinguishes "counter is 0" from "there is no counter" and keeps a
  counter-less HOTP entry from being imported with a guessed value.
- **Domain** is pure Dart, testable, imports no packages (even the crypto interface is abstract here).
- **Data** holds the Supabase + secure storage + libsodium implementations.
- Dependency injection: a **hand-written `get_it` composition root** (`lib/core/di/locator.dart`, `configureDependencies()`). `injectable` codegen was evaluated and dropped — it was never used.

---

## 4. Project Structure (feature-first)

```
lib/
├── main.dart
├── app/
│   ├── app.dart                 # MaterialApp.router
│   ├── router/                  # go_router config + guards (auth/lock)
│   └── di/                      # get_it registrations
├── core/
│   ├── crypto/                  # CryptoService interface + libsodium impl
│   ├── storage/                 # SecureStorage wrapper
│   ├── error/                   # Failure/Exception types
│   ├── network/                 # Supabase client wrapper
│   ├── theme/  · l10n/  · utils/
├── features/
│   ├── auth/                    # registration, login, master password, recovery
│   │   ├── data/ · domain/ · presentation/
│   ├── vault/                   # TOTP list, adding, code generation
│   │   ├── data/   (TokenRepository, SyncDataSource)
│   │   ├── domain/ (Token entity, GenerateCode, AddToken, SyncTokens)
│   │   └── presentation/ (VaultBloc, code cards, search, tag filter strip,
│   │                      widgets/ — AddTokenSheet, EditTokenSheet, TokenActionSheet, TagChipsBar, TagManagerSheet)
│   ├── scanner/                 # QR scanning + manual entry + "read from image" (Patch 3)
│   │   └── presentation/ (ScanPage, MigrationScanController — camera-free migration brain)
│   ├── import_export/           # Aegis / 2FAS / Google Authenticator import + encrypted backup (Phase 5 Patches 1–3)
│   │   ├── domain/  (ImportService, BackupService, BackupEnvelope, detectSource, dedupeKey, DocumentPort,
│   │   │            google_migration.dart — MigrationBatch + GoogleMigrationCollector,
│   │   │            qr_image_decoder.dart — QrImageDecoder seam + limits/exceptions)
│   │   ├── data/    (AegisParser, TwoFasParser, FilePickerDocumentPort,
│   │   │            protobuf_wire.dart — ProtobufReader, google_auth_parser.dart — GoogleAuthParser,
│   │   │            mobile_scanner_qr_decoder.dart — analyzeImage adapter)
│   │   └── presentation/ (ImportPage, ExportPage, widgets/ — ImportPreviewView, MigrationProgressBand)
│   ├── lock/                    # biometric/PIN app lock
│   └── settings/                # theme, language, account, change password
└── shared/                      # shared widgets
```

The `otp/` core (TOTP/HOTP/Steam algorithms) is isolated as a separate `core/otp/` module and validated against the RFC 6238/4226 test vectors with unit tests.

### 4.1 Import / Export (Phase 5 Patches 1–3)

`features/import_export/` follows the same domain/data/presentation split. `domain/` is pure Dart — parsers are
reached through the `ImportParser` interface and the file system through `DocumentPort`
(`pickJson({maxBytes})` / `saveJson({fileName, bytes})`), so both pages are testable without a platform plugin.
The concrete adapters live in `data/`.

- **`file_picker ^12.0.0`** (resolved 12.1.3), raised together with **`device_info_plus ^13.0.0`** (13.2.0) on
  2026-09-02. The earlier hold at 11.0.3 had a single cause — `file_picker >=12.1.3` pulls `windows_file_picker` →
  `win32 ^6.3.0` while `device_info_plus ^12.1.0` needed `win32 ^5.11.0` — so the two had to move as ONE upgrade,
  and they resolve cleanly together. What it buys: 12.x splits iOS/macOS into the federated `file_picker_darwin`,
  whose podspec depends on Flutter alone, so `DKImagePickerController/PhotoGallery` + `SDWebImage` + `SwiftyGif`
  are gone from `ios/Podfile.lock` — no photo-library code linked into a document-only app and no
  `NSPhotoLibraryUsageDescription` question at review. What it costs: the iOS deployment target rises 13.0 → 14.0
  (`file_picker_darwin` podspec; `ios/Podfile`, `Runner.xcodeproj` and `AppFrameworkInfo.plist` follow), which
  loses no hardware — iOS 14 supports the same devices as iOS 13 (iPhone 6s and later).
- **The 12.x API is federated and byte-lazy.** `FilePickerDocumentPort` uses `pickFile()` → `PlatformFile`, reads
  through `readAsBytes()` (from the plugin's own cached copy — `withData` is deprecated), and `saveFile()` now
  returns a `Uri?` rather than a path string. Because the facade dispatches through `FilePickerPlatform.instance`,
  the port's tests fake that platform interface instead of the method channel.
- **`path_provider ^2.1.5` is a DIRECT dependency**, not just a transitive one: `FilePickerDocumentPort` calls
  `getApplicationDocumentsDirectory()` itself to shred the copy iOS `saveFile` used to leave behind
  ([docs/CRYPTO.md §16.5](docs/CRYPTO.md)). `file_picker_darwin` 1.0.4 stages that copy in
  `NSTemporaryDirectory()` instead of Documents (so it no longer rides into the iCloud backup), but the shredder
  is KEPT as defence in depth — it is the only thing that would catch the destination moving back.
- **`VaultCubit.addAll(List<OtpAccount>)`** applies a whole import with a single persist and a single push instead
  of N calls to `add()`. Callers de-duplicate first.
- **Routes `/import` and `/export`** are children of the unlocked ShellRoute and are listed in the router guard's
  unlocked allow-list, so reaching them while locked still redirects to unlock.
- **Lock exemption:** the system file picker backgrounds the app, so both flows are wrapped in
  `VaultLockCubit.beginSystemFileFlow()` / `endSystemFileFlow()` — a budgeted, deliberate threat-model concession
  documented in [docs/CRYPTO.md §17](docs/CRYPTO.md).
- **Dedupe canonicalization is catalog-driven and shared.** `domain/dedupe.dart` builds the dedupe key from the
  Base32-canonicalized secret plus the issuer reduced to its `IssuerAvatar.slugFor` slug (lower-case, non
  alphanumerics dropped), so `GitHub` and `github.com` collapse onto one key. The slug alone cannot resolve an
  *alias* — `AWS` vs `Amazon Web Services` are different strings by any spelling rule — so `canonicalizerFor(
  IssuerCatalog)` in the same file is the single source both `VaultCubit` (on write) and `ImportService` (before
  dedupe) use, and the locator hands both the same catalog. Applying it on only one side is what produced
  duplicate tokens on re-import. **Known limit:** no Unicode NFC/NFD normalization — a precomposed `é` and its
  decomposed form still key differently; fixing it needs a package the project does not carry.
- **Entry ceiling on the file path:** `ImportService.maxEntries = 1024` (accounts + skipped), matching the
  Google path's `maxAccounts`. Over it the file is rejected whole with `ImportTooManyEntriesException` rather
  than truncated — importing the first 1024 of a 5000-entry file would leave the user believing it all came
  across. `ImportFileTooLargeException` guards bytes; this one guards count, which a small file of tiny entries
  blows past on its own.
- Supabase schema is **unchanged**: imported tokens travel the existing encrypted-blob path.

**Patch 2 — Google Authenticator transfer QR.** The export is a base64 protobuf in
`otpauth-migration://offline?data=…`, not an `otpauth://` URI, so it enters through the camera rather than the
file picker:

- **`data/protobuf_wire.dart`** — `ProtobufReader` (tag / varint / length-delimited / skip) plus the hard limits
  (8 KiB URI, 64 KiB payload, 256 entries per code, 1024 accounts, 10-byte varints). No codegen; see §3.
- **`data/google_auth_parser.dart`** — `GoogleAuthParser.looksLikeMigrationUri` / `parseUri`: manual query
  splitting (`Uri.queryParameters` would turn base64 `+` into a space), then the field mapping onto `OtpAccount`,
  with every unmappable entry recorded as a `SkippedEntry` instead of failing the code.
- **`domain/google_migration.dart`** — `MigrationBatch` + `GoogleMigrationCollector`: stitches a multi-QR export
  back together in any scan order, pinned to the first code's `batch_id`/`batch_size`; a code from another export
  is never merged, and a partial import is a legitimate result.
- **`features/scan/presentation/migration_scan_controller.dart`** — the camera-free brain of the flow (collector +
  `ImportService.previewParsed`); `ScanPage` only renders what it returns, which is what makes the whole rule set
  testable without a camera. `ScanPage` switches into migration mode by schema detection — **no new route, no
  guard or DI change** — and is now wrapped in `SecureScreenScope`.
- **`presentation/widgets/import_preview_view.dart`** — the confirm-preview block, shared by the file import and
  the QR import so both show one set of strings.

**Patch 3 — tags, pasted migration links, QR from an image file.** Three features, one theme: everything Patch 2
could only do with a live camera now has a second route in, and imported groups finally survive the import.

- **`core/otp/otp_account.dart` → `OtpAccount.tags`** — at most 8 labels of at most 32 runes, normalized by
  `normalizeTags` and stored **inside the encrypted blob**. No record version bump, no AAD change, no backup
  envelope change; the key is omitted entirely when empty, so an untagged vault serializes byte-identically to a
  pre-Patch-3 one and upgrading triggers no re-encrypt/re-push wave. `tags` IS in `props`, because
  `EncryptedVaultRepository`'s unchanged-blob shortcut compares `prev.account == account` — leaving it out would
  make a tags-only edit reuse the old ciphertext and vanish. `dedupeKey` deliberately ignores tags. Reasoning in
  [docs/CRYPTO.md §9](docs/CRYPTO.md).
- **`VaultCubit.editMetadata / renameTag / deleteTag / allTags`** — metadata-only editing (the signature does not
  even accept `secret`/`type`/`algorithm`/`digits`/`period`/`counter`), plus vault-wide tag rename and delete.
  Each follows the `addAll` shape: one `_emitAndPersist` and one `_pushAfterMutation` for the whole sweep, and a
  no-op writes and pushes nothing. `allTags` is a pure derivation of state (usage count descending).
- **Import group → tag mapping** (`data/aegis_parser.dart`, `data/twofas_parser.dart`): Aegis reads `db.groups`
  (`{uuid, name}`) through the entry's `groups: [uuid]` array, plus the legacy singular `entry.group` which holds
  a NAME; 2FAS reads the root `groups` (`{id, name}`) through `service.groupId`, so a 2FAS service yields at most
  one tag. Google's migration payload has no grouping field at all. An unresolvable reference contributes no tag
  **in silence** — it produces no `SkippedEntry`, and nothing about groups can ever drop an entry.
- **`domain/qr_image_decoder.dart`** — `typedef QrImageDecoder = Future<List<String>> Function(String path)` plus
  `QrImageLimits.maxBytes` (16 MiB) and the two outcomes the UI must tell apart:
  `QrImageUnsupportedException` (iOS Simulator, web — another image would not help) vs
  `QrImageUnreadableException`. `data/mobile_scanner_qr_decoder.dart` is the only real implementation, a thin
  adapter over `MobileScannerPlatform.instance.analyzeImage` — which needs **no camera and no camera permission**.
  It is **not in DI**: `ScanPage` defaults to `const MobileScannerQrDecoder().call` and takes a
  `@visibleForTesting` override, so the whole flow is host-testable with a closure.
- **`DocumentPort.pickImage({maxBytes})` + `clearPickerCache()`** (`domain/file_port.dart`,
  `data/file_picker_document_port.dart`) — returns a `PickedImage` by **path**, not bytes (the decoder takes a
  path, so a multi-megapixel photo is never pulled into Dart memory), and unlike `pickJson` does not clear the
  cache on the way out; the caller owns that. The shred order in the caller's `finally` is load-bearing — see
  [docs/CRYPTO.md §16.5](docs/CRYPTO.md).
- **`presentation/widgets/migration_progress_band.dart`** — the old private `_MigrationBand` lifted out of
  `ScanPage` unchanged, now with parameterised label/hint strings, because a second collector screen reuses it.
- **`features/vault/presentation/widgets/add_token_sheet.dart`** — the old private `_AddSheet` lifted out of
  `VaultPage`, and now the home of the **pasted migration link**: a `otpauth-migration://` paste goes to a
  `MigrationScanController` owned by the sheet, an incomplete batch shows the progress band, a complete one opens
  `ImportPreviewView` inside the sheet. The clipboard is never read programmatically — the user pastes.
- **`features/scan/presentation/scan_page.dart`** — an AppBar "Görüntüden oku" action, independent of camera
  state. Every decoded string re-enters the existing `_handleRaw`, so both single-token and migration mode work
  from an image. Wrapped in the same budgeted lock exemption as the file flows
  ([docs/CRYPTO.md §17](docs/CRYPTO.md)), now a three-flow list.
- **New vault widgets** (`features/vault/presentation/widgets/`): `tag_chips_bar.dart` (single-selection,
  session-scoped filter strip, hidden when the vault has no tags), `token_action_sheet.dart` (long press → Düzenle
  / Etiketler / Sil), `edit_token_sheet.dart` (issuer / account name / tags; never reads the secret),
  `tag_manager_sheet.dart` (rename / delete a tag across the vault).
- **No new route, no guard change, no DI change** beyond the existing `DocumentPort` registration, and the
  `SecureScreenScope` list is unchanged at 11 screens (`grep -rn "SecureScreenScope(" lib/`).
- Supabase schema is **unchanged**: tags travel inside the same encrypted blob the tokens already use, so the
  server sees no new column, no new field and no size class it did not see before.

---

## 5. Supabase Data Model & RLS

### Tables
```sql
-- User crypto metadata (the server sees no plaintext key)
key_attributes (
  user_id uuid PK references auth.users,
  kdf_salt bytea,            -- Argon2id salt
  kdf_ops int, kdf_mem int,  -- Argon2id parameters
  encrypted_master_key bytea, master_key_nonce bytea,        -- wrapped with KEK
  recovery_encrypted_master_key bytea, recovery_nonce bytea, -- wrapped with recovery key
  created_at timestamptz
)

-- Encrypted TOTP entries (the server cannot see the content)
tokens (
  id uuid PK,
  user_id uuid references auth.users,
  ciphertext bytea,          -- XChaCha20-Poly1305(token JSON)
  nonce bytea,
  version int,               -- schema/encryption version
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(), -- for sync/conflict (set by server-side trigger)
  deleted bool default false -- soft delete (sync consistency)
)

devices (user_id, device_id, name, last_seen, push_token)  -- multi-device + FCM
announcements (id, title, body, audience, created_at)       -- admin announcements
catalog_services (id, name, issuer, logo_url)               -- catalog of supported services
audit_logs (id, actor, action, target, created_at)          -- admin operation log
feature_flags (key text PK, enabled bool, payload jsonb, updated_at) -- feature flags
```

> **Note:** the above is a **schema summary**, not migration-ready DDL. Production details to be added to each table in the Phase 3 migration: `not null` + `default`s, PK/FKs (`references auth.users on delete cascade`), a composite PK `(user_id, device_id)` for `devices`, an `index tokens(user_id, updated_at)` for sync, an `audit_logs(created_at)` index, and `id uuid default gen_random_uuid()`.

> **Migration step order (per table):** `create table` → `alter table ... enable row level security` → create the policies → **`grant`s last** (`grant ... to authenticated`, `to service_role` where needed). In new Supabase projects, public tables are **not automatically exposed** to the Data API — without an explicit grant, `supabase_flutter` gets a permission error. Never grant without RLS.

### RLS policies
- `enable row level security` first on every table (mandatory — a table that has been granted while RLS is off becomes public to everyone).
- `tokens`, `key_attributes`, `devices`: policies target **`to authenticated`**; `using (user_id = (select auth.uid()))` and `with check (user_id = (select auth.uid()))` — a user sees only their own rows. (Restricting the role with `to authenticated` rules out `anon` up front; `auth.uid()` returns `null` for anon and matches no row, but explicitly stating the role is still best practice.) **The `(select auth.uid())` wrapping is mandatory:** init-plan optimization — Postgres evaluates `auth.uid()` once per query rather than per row (bare `auth.uid()` triggers the Supabase `auth_rls_initplan` performance warning; see migration `20260606152553`).
- `announcements`, `catalog_services`, `feature_flags`: **read by `anon` + `authenticated`** (visible before login too — for the splash/login screen). The read policy is `to anon, authenticated` + `grant select` to both roles. **Writes only via the server-side secret key** (service_role bypasses RLS) → no separate admin write policy, no write grant to `authenticated`. (This is consistent with the "all authorized writes are server-side" decision.)
- `audit_logs`: reads admin-only; inserts via the **server-side secret key (legacy service_role) / Edge Function** (not from the client).

#### Admin role (correct syntax)
The claim is NOT the top-level `role` — that is the Postgres role. The admin flag must be carried under `app_metadata` and added there via a **Custom Access Token Hook** (it does not appear automatically):

```sql
-- 0) Table holding the admin flag (instead of writing directly to auth.users)
create table public.admin_users (user_id uuid primary key references auth.users on delete cascade);
alter table public.admin_users enable row level security;  -- no policy → the client cannot access it

-- 1) Custom Access Token Hook function: adds app_metadata.admin=true to the
--    admin user's access token. (Enabled via Dashboard > Auth > Hooks.)
create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb language plpgsql stable as $$
declare claims jsonb; admin boolean;
begin
  select exists(select 1 from public.admin_users a where a.user_id = (event->>'user_id')::uuid) into admin;
  claims := event->'claims';
  if jsonb_typeof(claims->'app_metadata') is null then
    claims := jsonb_set(claims, '{app_metadata}', '{}');
  end if;
  claims := jsonb_set(claims, '{app_metadata, admin}', to_jsonb(admin));
  return jsonb_set(event, '{claims}', claims);
end;
$$;

-- 2) Hook permissions: only the auth admin runs it; revoked from everyone (security)
grant usage on schema public to supabase_auth_admin;   -- MANDATORY: so the hook can access the public schema
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from authenticated, anon, public;
grant select on table public.admin_users to supabase_auth_admin;  -- so the hook can read the table
revoke all on table public.admin_users from authenticated, anon, public;

-- 2b) MANDATORY: because RLS is on for admin_users, the grant alone is not enough —
--     supabase_auth_admin needs an explicit SELECT policy, otherwise the hook cannot see the row
--     and the admin claim ALWAYS stays false.
create policy "auth admin reads admin_users" on public.admin_users
  as permissive for select to supabase_auth_admin using (true);

-- 3) Helper: is_admin() — used in RLS policies
create or replace function public.is_admin()
returns boolean language sql stable set search_path = '' as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'admin')::boolean, false);
$$;

-- 4) is_admin() usage example: the admin READING audit_logs from their own (authenticated) client.
--    NOTE: there is NO separate policy for WRITING to admin-public tables — writes go through the server-side secret key
--    (service_role bypasses RLS). is_admin() is used only in read restrictions.
create policy "admin reads audit_logs" on public.audit_logs
  for select to authenticated using (public.is_admin());
```

> **Important:** authorized operations (suspending/deleting a user, audit_logs insert, triggering push) are performed with the **secret key** (the legacy `service_role` equivalent), and this key is held only server-side (Next.js route handler / Edge Function) — never embedded in the browser/app.

> **Reading the claim on the client (a trap):** the `app_metadata.admin` claim added by the hook is written **into the access token (JWT)**; it may not appear in the `session.user.app_metadata` object. When the middleware/app verifies this, it must decode `session.access_token` and read the claim from there (or use `getClaims()`) — trusting `user.app_metadata` is misleading.

> **E2E guarantee:** `tokens.ciphertext` and all key fields in `key_attributes` are meaningless blobs to the server. Even the secret key (although it bypasses RLS) **cannot decrypt their contents** — the decryption key resides only on the user's device. The admin panel only sees counts/metadata.

### Sync (Realtime)
- **Publication:** `alter publication supabase_realtime add table public.tokens;` (otherwise changes are not published). Realtime is subject to RLS — a user receives only their own row events.
- **Pull + subscription order (race window):** the order must be **subscribe first, then pull** — otherwise a change arriving between the end of the pull and the subscription becoming active is missed. The correct flow: (1) subscribe to Realtime and buffer incoming events temporarily, (2) do a catch-up pull with `updated_at > last_sync`, (3) merge the buffered events with the pull result (idempotent, `id`-based upsert; newest wins by `updated_at`). Alternative: a second catch-up pull after the subscription is ready. In all cases the merge is idempotent by `id`+`updated_at`, so double application is harmless.
- **Trusting `updated_at` via a server-side trigger:** the client-sent timestamp is not trusted. A `before insert or update` trigger sets `updated_at := now()` (eliminating clock skew). **TWO separate functions are needed** — writing `new.created_at := now()` to a table that has no `created_at` raises `record "new" has no field "created_at"`:
  ```sql
  -- tables with both created_at + updated_at (tokens, key_attributes)
  create or replace function public.touch_timestamps() returns trigger language plpgsql set search_path='' as $$
  begin if (tg_op='INSERT') then new.created_at := now(); end if; new.updated_at := now(); return new; end; $$;
  -- tables with updated_at only (feature_flags)
  create or replace function public.touch_updated_at() returns trigger language plpgsql set search_path='' as $$
  begin new.updated_at := now(); return new; end; $$;
  create trigger trg_tokens_touch before insert or update on public.tokens
    for each row execute procedure public.touch_timestamps();
  ```
- **Soft delete:** deletion = `update ... set deleted=true`. It is published as an UPDATE; the other device hides the row. A real `delete` is not used (because of sync consistency + the limited Realtime DELETE payload).
- **Conflict resolution — arrival-order LWW (Phase 3 model):** since `updated_at` is set server-side with `now()`, on a conflict it is **the one that reaches the server last**, not "the last to edit", that wins. When the same token (same `id`) is edited concurrently on two devices, the UPDATE that reaches the server second overwrites the first; one device's change may silently be lost. This is a **deliberately accepted** simplification for Phase 3.
  - Note: if "the truly last editor wins" is desired, the schema is extended with `client_modified_at timestamptz` + `revision int` (+ `device_id`) fields and LWW is done by client time; the current single `id` cannot be a tie-breaker because `id` is already the same for the same token.
  - For heavy multi-device usage, a CRDT/vector clock will be considered later — see open decisions.
  - **Tags do not change the sync contract, but they widen its blast radius (Phase 5 Patch 3).** `OtpAccount.tags`
    lives INSIDE the encrypted blob, so the server still sees one opaque `ciphertext` per token: no new column, no
    new field, and LWW still resolves **per record**. What is new is that one user gesture can now dirty *many*
    records at once — `VaultCubit.renameTag`/`deleteTag` rewrite every token carrying the tag, so a rename over N
    tokens pushes N changed records (in a single persist and a single push, but still N rows). Under arrival-order
    LWW that means the conflict radius of a tag operation is N, not 1: a concurrent edit of any one of those N
    tokens on another device can lose that device's change for that record. Accepted for now, and listed as an open
    decision in [PLAN.md](PLAN.md) (risk R3) — the fix is the same `client_modified_at`/`revision` extension the
    note above describes, plus possibly a field-level merge, and neither is worth doing before the LWW model
    itself is revisited.

---

## 6. Admin Panel (Next.js)

- **Stack:** Next.js (App Router) + TypeScript + Supabase JS SDK + shadcn/ui + TanStack Table + recharts.
- **Access:** only users with the `app_metadata.admin=true` claim; Supabase session + claim check in Next.js middleware.
- **Authorization boundary (critical) — read model corrected:**
  - Since the RLS on user data (`tokens`, `key_attributes`, `devices`) is `user_id = auth.uid()`, the admin **cannot read these globally with a normal client**. For this reason the admin's **cross-user reads** (user list, global counts/analytics) are done **server-side**, by calling a **`security definer` aggregate function in a private schema directly over a Postgres connection** (returning only aggregates/metadata, not raw rows).
  - **Do not conflate the two separate access paths (important):**
    - **(a) Direct Postgres connection** (`DATABASE_URL`/pooler + an appropriate DB role): used to call functions/SQL in the private schema. Cross-user aggregate reads are done **via this path**. RLS is enforced according to the connection's DB role (a role with `bypassrls` or the `security definer` owner of the function).
    - **(b) Supabase secret key** (`sb_secret_...`, the REST/Auth API identity): for **API** calls such as `auth.admin` (delete/suspend a user), Storage, REST. This is **not** a Postgres connection credential; it does not call a DB function directly.
    - In short: aggregate read → (a); `auth.admin`/API operations → (b). Both are server-side, both are never embedded in the browser.
  - **`security definer` aggregate function guardrails (mandatory):**
    - **Create it in a non-exposed private schema** (e.g. `private` / `admin_api`) — `security definer` functions are **never** kept in a schema that is in the "Exposed schemas" list in the API settings (including public if it is exposed).
    - **Invocation path (mind the conflict):** because this schema is **not** exposed to the Data API, it **cannot be called remotely** via `supabase-js` `.rpc()` / `.schema()` (the Data API only sees exposed schemas). For this reason the private function is called from inside a Next.js route handler / Edge Function via a **direct Postgres connection (server-side SQL)** — not via the secret key over REST/RPC. (Alternative B: if you wish to put the function in an `api` schema and expose it, then to limit the `security definer` risk it is designed separately with a thin wrapper + strict `revoke`/`grant`; in this project the preference is A — a private schema + direct connection.)
    - Define it with `security definer set search_path = ''` (this prevents search_path injection; give all objects schema-qualified references, e.g. `from public.tokens`).
    - `revoke execute on function ... from public, anon, authenticated;` — the function is not left open to the Data API.
    - `grant execute` is given only to the **DB role** the backend uses over the direct connection — `anon`/`authenticated` cannot call it. (Note: this is the Postgres connection role on path (a), not the REST secret key.)
    - The function returns **only aggregates/metadata** (counts, date histograms); it never returns raw `ciphertext`/rows.
    - Validate the inputs inside the function (against parameter injection), and add an admin check at the start of the function if needed.
  - Only the **admin-public tables** (`announcements`, `catalog_services`, `feature_flags`) can be read with a normal `authenticated` client (there is already a select-to-everyone policy).
  - **Writes/authorized operations** (suspending/deleting a user, audit_logs insert, sending push) are done only inside a **server-side route handler / Edge Function** with the secret key. The secret key is never sent to the browser.
  - **Important:** even though the backend bypasses RLS (whether direct DB or secret key), because of E2E it **cannot decrypt** the contents of `tokens.ciphertext` — only metadata/counts. A cross-user read says "how many tokens there are", not "what is inside them".
- **Supabase key terminology (2026):** for new projects, Supabase recommends a **publishable key** (`sb_publishable_...`, the old `anon`) for the client and a **secret key** (`sb_secret_...`, the old `service_role`) for the backend. The legacy `anon`/`service_role` are **being deprecated through the end of 2026** (on the deprecation track); in a new project prefer publishable/secret from the start. In this document "secret key" = the legacy `service_role` equivalent; backend-only. (The Postgres roles `authenticated`/`service_role` are a separate matter — they persist as grant/RLS targets.)
- **New secret key usage detail (Edge Function / HTTP — the 401 trap):** the new `sb_secret_...` keys are **not** JWTs. They are sent in the request via the **`apikey` header**; **do NOT use `Authorization: Bearer <secret>`** — the platform tries to parse it as a JWT and returns `Invalid JWT` (401). On Edge Functions that use these keys, set `verify_jwt = false` (config.toml) and do the authorization inside the function code (or split user/admin clients with `@supabase/server`). To verify user requests, the user's own token is processed separately.
- **Capabilities:**
  - User management: list, search, suspend/delete — since listing/counting is cross-user, via **(a) direct Postgres connection + private aggregate function**; deleting/suspending via **(b) secret key + `auth.admin` API**. Both are **server-side**. Account metadata, not content.
  - Analytics: user/device/token counts (totals, not content), growth charts.
  - Announcements/notifications: write `announcements` + trigger push via FCM (Edge Function).
  - Service catalog management: logo/issuer CRUD.
  - Feature flags + audit log viewing.
- **Important boundary:** because of E2E, the panel cannot decrypt/see any TOTP secret — only metadata and counts.

---

## 7. Authentication Flow

- **Login password ≠ master password.** The Supabase Auth session (email/password, then OAuth) is for identity; the master password is for the E2E key. The two are kept separate (security + independence of password reset). They **do NOT DERIVE** from each other (a fully disjoint flow).
- Abstracted via an `AuthRepository` interface → email/password first, Google/Apple added later (without changing code).

### Two independent "gates" (Phase 3 Patch 1 — implemented)

Two orthogonal but **sequential** states: first the Supabase session (identity), then the vault lock (E2E).

```
SessionStatus (identity)             VaultLockStatus (E2E)
  unknown → /splash                   uninitialized → /setup
  signedOut → /auth/login             locked        → /unlock
  emailConfirmPending → /auth/confirm  unlocked      → /  (vault)
  signedIn → the vault guard runs
```

- The **combined guard (`sessionGuard`)** keeps the identity gate OUTERMOST; the **vault guard (the shell
  that requires masterKey) runs only in the `signedIn && !linkRequired` branch**. During `unknown`,
  `/splash` is shown → the vault shell is not rendered before `signedIn` (no `masterKey` null crash).
- **Email confirmation is MANDATORY** (PKCE + deep-link `dev.mustafakara.projectauth://login-callback`;
  Android intent-filter VIEW+DEFAULT+BROWSABLE, iOS `CFBundleURLTypes`). `emailConfirmPending`
  is PERSISTED (the confirmation screen on relaunch; a "Use a different email" exit).
- **`onAuthStateChange` `onError` is MANDATORY** (gotrue surfaces a network error as a stream error → without it the app crashes).
- **signOut** clears the local vault (masterKey/mnemonic) BEFORE the network signOut (at every stage);
  even on a network error, `signedOut` is reached (gotrue deletes the local token first).
- **Multi-vault per uid:** a SEPARATE local vault namespace (`'<uid>/'`) for each Supabase uid. On the first
  login, if a uid-less Phase 2 vault exists, an explicit **account-linking** confirmation (`/auth/link`): link
  (migrate + clear/re-enroll `bmk`) / new empty vault. A per-uid decision marker → no guard loop.
- Startup flow: is there a Supabase session? → (new device: restore key_attributes — Patch 2) → can the master
  key be unlocked on the device (biometrics)? → if not, ask for the master password → enter the vault.

---

## 7.5 Local → Cloud Transition (Phase 1 → 2 → 3)

The clear responsibility of each phase regarding the vault (to resolve the conceptual overlap):

| Phase | Vault state | Master key | Cloud |
|---|---|---|---|
| **Phase 1** | Local, **unencrypted** (only `flutter_secure_storage`'s own OS protection) | none | none |
| **Phase 2** | Local, **E2E-encrypted** — master key + master password + recovery + biometric unlock are set up and local tokens are encrypted with `masterKey` | yes (on device) | still none (can be demoed offline) |
| **Phase 3** | The same E2E-encrypted data is **synced to the server** (no extra encryption since it is already encrypted) | yes | encrypted blob upload to Supabase + Realtime |

> **Decision:** E2E encryption is completed **in Phase 2** (without the cloud). Phase 3 adds no new encryption layer; it merely moves the tokens that were already encrypted with `masterKey` in Phase 2 to the server as `key_attributes` + `tokens`. This eliminates the "first encryption in Phase 3" contradiction.

**First-login backfill flow (Phase 3):**

1. **Single-vault abstraction:** `TokenRepository` is a single interface from Phase 1 onward; behind it sit `LocalTokenSource` and (in Phase 3) `RemoteSyncSource`. The View/Bloc does not see this transition.
2. **Token identity:** every token carries a stable `id` (uuid) from Phase 1 onward → prevents duplicates during backfill.
3. **First-login backfill:** the local tokens already encrypted with `masterKey` in Phase 2 are **upserted** into the `tokens` table (update on `id` conflict). The operation is idempotent — running it again produces no duplicates. (If unencrypted tokens remain from Phase 1, they first go through the Phase 2 encryption.)
4. **Ordering:** first the master key + `key_attributes` upload, then the token backfill. If interrupted midway, it is retried on the next startup with `last_sync=epoch`.
5. **Conflict:** if the same `id` is both local and in the cloud (e.g. a second device), arrival-order LWW (server-side `updated_at`) is applied.

### key_attributes upload/restore (Phase 3 Patch 2 — implemented; token sync in Patch 3)

Patch 2 syncs ONLY the crypto **metadata** (not the tokens). Everything sent to the server is already opaque:
`encrypted_master_key`/`recovery_encrypted_master_key` (the masterKey wrapped with the KEK/recovery key) +
KDF `salt/ops/mem` + nonces. **The masterKey, KEK, recovery key, and plaintext TOTP secret NEVER go.** `bmk`
(the biometric wrap) does not go either — it is a device-local OS-keystore shortcut (no column in the server schema); a new device
re-enrolls biometrics.

- **bytea interop (`ByteaCodec`, single point):** PostgreSQL `bytea` ↔ `Uint8List` (`\x`+hex). The local
  `EncryptedBlob` keeps the nonce+ciphertext TOGETHER; the server (`key_attributes`) uses SEPARATE columns
  (`*_nonce` / `encrypted_master_key`) → on upload the blob is split IN TWO, on restore it is reconstructed from the two columns.
  The `bytea` JSON-body INSERT format is verified on the first device; if wrong, it is fixed in a single file (the schema does not change).
  Because Realtime double-encodes `bytea` (#1180), Realtime is ONLY a trigger (Patch 3) — the actual data is REST.
- **Upload (backfill):** once the vault is `unlocked` (inside `VaultLockCubit`, best-effort), if NO record exists
  on the server, `insert` (guarded). If one EXISTS, DO NOT OVERWRITE → **server-wins**; a master-password change on one device
  (`changePassword`) does NOT INTENTIONALLY update the server (multi-device consistency via Patch 3 `updated_at` LWW).
- **Restore (new device):** if `bootstrap` finds no local attrs, it emits a **`restoring` state BEFORE the fetch**
  (router `/splash`; the user does not see `/setup` → cannot set up a new vault and create a double-vault before the fetch finishes).
  remote EXISTS → write to local + `locked` (master password). A genuine 0-row → `uninitialized` (setup). A network/RLS
  error (`SyncError`) → a separate **`restoreFailed`** screen (retry / switch account) — does NOT
  FALL BACK to `uninitialized`. A network error and a genuine 0-row are STRICTLY distinguished (the repository returns `null` on 0-row and throws `SyncError` on error).
- **Multi-vault:** each uid is in its own namespace; with owner-only RLS + the uid namespace, A's attrs are not visible to B.
  A legacy uid-less vault does not connect to the server (`uid=null` → restore/upload no-op).

### token push/pull + changePassword UPDATE (Phase 3 Patch 3 — implemented)

Patch 3 syncs the encrypted **tokens** + closes Patch 2's changePassword gap. Only the
opaque `ciphertext`/`nonce` (+ `version`, `deleted`) go to the server; AAD is `token|1|<id>`. Token sync does NOT SEE the masterKey.

- **Layers:** `RawTokenStore` (= a SEPARATE face of `EncryptedVaultRepository` — `exportRaw`/`importRemote`/
  `markDeleted`; NO decrypt, reads/writes raw from disk) + `RemoteTokenRepository`/`SupabaseTokenRepository`
  (opaque transport; `ByteaCodec` + `SyncError`) + `TokenSyncService` (cursor + push/pull/merge + Realtime).
  The decrypted `VaultRepository` (`load/save/purgeCorrupted`) DOES NOT CHANGE → existing tests/VaultCubit are preserved.
- **Arrival-order LWW:** the server `updated_at` is the only valid ordering (not compared against client epoch-ms); each record
  keeps `sv` (the last reconciled server cursor). For local-dirty (`sv=null`), the pull-cursor distinguishes echo-vs-new.
  The merge is id-based + idempotent. `importRemote(rows, {pullCursorIso})` — the cursor is a parameter to the merge.
- **The merge write is UNDER the VaultCubit mutation queue:** `TokenSyncService` does NOT call `importRemote`
  DIRECTLY; the `mergeRemote` callback → `VaultCubit.applyRemoteMerge` (import + reload in a SINGLE critical section,
  the `_opChain` sequencer) → does not race with concurrent user add/delete/increment (the merge and the mutation serialize in the same
  single write queue). Push is best-effort (its own `try/catch`) → a push error does not block the pull.
- **Soft-delete (tombstone):** `markDeleted` writes a tombstone with the last blob + atomically; `load()` does not
  show it in accounts, `exportRaw` returns it for push; it is preserved across saves (the token is not resurrected).
- **A live record beats its own tombstone (deliberate resurrection).** One id may never carry both a live record
  and a tombstone, so `_writeRecords`, `load` and `importRemote` all drop the tombstone when a live record for the
  same id is present. The pair can only arise from an **id-preserving backup restore of a token the user had
  deleted** — which is exactly the user asking for that token back. The restored record is dirty (`sv == null`),
  so the next push flips the server row to `deleted = false`. Keeping both instead would lose the token silently
  at the next `importRemote` (the tombstone wins the merge) and would break push permanently, because
  `pushUpsert(onConflict: 'id')` rejects two rows with the same id (Postgres 21000).
- **One record per id leaves the store.** `exportRaw` (and, defensively, `TokenSyncService._pushDirty`) collapses
  duplicates before anything is pushed, by the same rule: live beats its own tombstone, and between two of the
  same kind the first on disk wins — never the last, which could turn a resurrection back into a tombstone. The
  duplicate is reachable without any file corruption: `_corruptedRaw` keeps records that are schema-valid but
  undecryptable, so one id can sit there *and* in `_lastById` and be written twice. `_pushDirty` repeats the
  collapse because `RawTokenStore` is a port — another implementation, or a hand-edited file, can hand it a
  duplicate the repository never saw.
- **Null pull-cursor: the dirty local record wins.** `pullCursorIso == null` means this device has never
  completed a pull, so nothing can prove a server row is *newer* than an unpushed local record — and assuming the
  server wins undid the resurrection rule above in exactly the case it exists for (restore a backup, resurrect a
  deleted token, first sync, server tombstone deletes it again). Ids with no local record are still always
  applied, so a first pull still brings the whole remote vault down; only records awaiting push are protected,
  and the collision is resolved by server-side LWW once that push lands.
- **Push and merge are serialized inside `TokenSyncService`** by an async mutex covering `exportRaw + pushUpsert`
  on one side and the merge write on the other. Otherwise a long import push and an arriving merge interleave: the
  merge writes a newer blob to disk while the push is still uploading the snapshot it read beforehand, so the
  server keeps the **stale** blob and the next pull hands it back. The lock is the service's own, not `VaultCubit`'s
  `_opChain` — the cubit's sequencer guards UI mutations and must not have a network round trip parked in it.
  **The pull sits BETWEEN the two locked regions, not inside either:** `pullSince` runs unlocked, so a
  `pushChanged()` slipping in between means the merge applies rows that were read before that push. That is not a
  loss — arrival-order LWW plus the dirty (`sv == null`) rule decide the outcome, and the pushed record stays
  dirty until a later pull reconciles it. Holding the lock across the network call instead would block every user
  mutation for the length of a round trip, which is the cost the service-local lock exists to avoid.
- **Kill-switch re-enable does a catch-up.** While `token_sync_enabled` is false, `syncOnce`, `pushChanged` and the
  Realtime trigger are all no-ops, so server rows and local dirty records pile up. Restoring the subscription is not
  enough — Realtime only announces what happens *next* — so a false→true transition runs a `syncOnce` in the same
  subscribe-first-then-pull order as `start`.
- **Realtime = trigger only (#1180):** the payload is NOT READ → REST `pullSince`. Order: subscribe-first → catch-up
  pull → idempotent merge. The subscription is tied to the VaultCubit subtree lifecycle (start on unlock, on lock/background/
  signOut `VaultCubit.close → sync.dispose → unsubscribe`). Live sync is a Settings toggle (off by default).
- **Corrupt-remote-row quarantine:** a single malformed row in a successful response is skipped + counted (the vault does not fall);
  the cursor only advances to the last-valid before the first-malformed (`safeCursorIso` cap) → no gap is skipped. A network/RLS
  error (the whole request) is `SyncError` (the cursor does not advance) — distinct from a single corrupt row.
- **changePassword (key_attributes UPDATE):** the masterKey DOES NOT CHANGE → NO token re-encrypt; only
  the `key_attributes` row is UPDATEd (LWW). On a network error → an `attrs_dirty_v1` marker → dirty-replay retry on unlock.
  On a conflict the last-arriving wins (no data loss; the loser works with local attrs, the recovery wrap does not change).
- **`uid==null` (legacy/uid-less) → sync INERT** (byte-identical old behavior). DELIBERATE limits: token sync
  only when unlocked; force-push re-wrap out of scope; tombstone GC later.

### devices + catalog/feature_flags/announcements (Phase 3 Patch 4 — implemented)

Patch 4 adds three extra capabilities OUTSIDE identity/sync — **WITHOUT TOUCHING the E2E surface** (NO new crypto; none of these tables
carry a secret/masterKey). The server schema DID NOT CHANGE. None are in Realtime → fetch-on-event + cache.

- **`devices` (owner-only RLS, composite PK `user_id,device_id`):** `device_id` = a random `uuid v4`,
  in **GLOBAL** secure storage (`StableDeviceIdStore`; uid-independent — NOT hardware-derived, privacy-friendly,
  changes on reinstall). `DeviceRegistrar`: signedIn → `register` (idempotent upsert); resume → `last_seen`
  heartbeat, **if 0 rows are affected, `register` fallback** (if the initial register failed with a network error, it creates the server row).
  Only an opaque UUID + `last_seen` go to the server; no trigger → the client writes `last_seen`. Best-effort.
  **Cross-account correlation TRADEOFF (ACCEPTED):** multiple accounts on the same device → the backend can correlate the accounts
  through the same `device_id`; accepted for simplicity for multi-device list consistency (a per-uid
  `HMAC(secret,uid)` is a future refinement — see docs/CRYPTO.md).
- **Public read tables (anon+authenticated SELECT; NO client write grant):** repo + global cache +
  offline fallback. The backend (service_role) writes; the client reads only.
  - `catalog_services` → **issuer canonicalization**: AFTER QR/manual parse, INSIDE `VaultCubit.add` the issuer is
    aligned to the catalog's canonical name (both add paths go through a single choke-point). `IssuerCatalog.canonicalIssuer`
    REUSES `IssuerAvatar.slugFor` (avatar/catalog slug consistency). **`logo_url` is IGNORED**
    (the `IssuerAvatar` decision "NO runtime logo fetching — offline/privacy" is preserved; no network image is downloaded). If the catalog
    is empty/no match → no-op (the issuer does not change).
  - `feature_flags` → **`token_sync_enabled` kill-switch** (`FeatureFlagsService`): the server can remotely disable
    token push/pull/live. **The gate is INSIDE `TokenSyncService`** (all entry points + `_onRealtimeEvent` → no Realtime
    bypass when off; the VaultCubit gate alone does not cover Realtime). When the flag flips to false, `FeatureFlagsService.
    listenable` notify → sync SELF-SUBSCRIBE does `disableLive`; true + livePref → `enableLive` (toggle "on" ⇔
    subscription active). `VaultCubit.load` does a bounded `ensureLoaded` + `isEnabled` BEFORE `start` (prevents the fallback from
    accidentally starting sync on the first launch with an empty cache). **fallback=true** (no flag/offline/timeout → sync runs;
    only an explicit server `false` disables it). `isEnabled` reads ONLY the in-memory snapshot (the async cache is the job of `ensureLoaded`/bootstrap).
    **It gates ONLY the token transport — `key_attributes` restore/backfill/update ALWAYS runs** (identity recovery is critical).
  - `announcements` → a read-only section in Settings; **`audience` is a client-side filter** (RLS does not filter): `all`
    OR a platform (`flutter`/`android`/`ios`). feature_flags are not shown in the UI (internal only).
- **Global stores (device_id + catalog/flags/announcements cache) are NOT DELETED on vault reset** (uid-independent;
  PUBLIC data + the device id must stay the same on the next login). All new dependencies are optional/nullable → legacy/test unchanged.

---

## 8. Test Strategy
- **Crypto & OTP:** RFC test vectors + golden-file tests (encrypt→decrypt round-trip, password change, recovery).
- **Domain/UseCase:** pure unit tests (mock repository).
- **Bloc:** plain `flutter_test` + `mocktail` over the cubit's `stream`/`state` (`bloc_test` was removed on 2026-09-01 — unused).
- **Data:** integration against Supabase (test project) + mock.
- **E2E security test:** a test verifying that the payloads sent to the server are genuinely opaque.
- **RLS tests:** User A **cannot read/write** B's `tokens`/`key_attributes` rows (cross-user isolation). The test must fail when RLS is off (regression protection).
- **Admin claim tests:** `is_admin()` returns correctly based on the claim; a user with the admin claim can read `audit_logs`, one without it cannot; client writes (insert/update) to admin-public tables are rejected **because there is no grant** (writes are server-side only); authorized server-side endpoints reject requests without claim/secret verification.
- **Admin private function / secret key security tests:** the `security definer` aggregate function in the private schema **cannot be executed** by `anon`/`authenticated` (the revoke is verified); the function returns only aggregates/metadata (it does not leak raw rows/`ciphertext`); it is verified that the function is in a private (non-exposed) schema and cannot be called from the Data API.
- **Secret key header test:** when the secret key is sent with `Authorization: Bearer`, `Invalid JWT` (401) is received; it works with the `apikey` header + `verify_jwt=false` (regression protection — wrong header usage is caught).
- **GRANT test:** client access to a table without a grant gives a permission error (so it is not accidentally left open).
- **Sync/conflict tests:** a two-device simulation — on a concurrent update the **arrival-order LWW** behavior is verified (the one that reaches the server last wins, via server-side `updated_at`); a soft delete is hidden on the other device; no event arrives on a table that is not added to the Realtime publication.
- **Local→cloud transition test:** the encrypted upload/backfill of Phase 1 local tokens after the first login; no duplicates created (see §7.5).
