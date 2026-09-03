# Development Plan — Phased Roadmap

> Goal: a solid, complete architecture from the start. Because the Google/Apple developer accounts are not yet ready,
> social sign-in and push are "plugged in" after the account-independent parts are done — development is never blocked at any point.
> For the detailed architecture, see [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Phase 0 — Foundation setup (week 1) — MOSTLY COMPLETE (2026-06-06)
- [x] Flutter project (3.38.6) + feature-first folder skeleton (`lib/core/*`, `lib/features/{vault,scan}/*`). ✅
- [x] Dependencies added + versions resolved: `flutter_bloc 9.1`, `go_router 17.3`, `get_it 9.2`, `supabase_flutter 2.17`, `sodium_libs 3.4`, `flutter_secure_storage 10.3`, `mobile_scanner 7.4`, `local_auth 3.0`, `equatable`, `uuid`, `crypto`. ✅
  *(2026-09-01: `injectable`/`injectable_generator`, `freezed`/`freezed_annotation`, `json_annotation`/`json_serializable`, `build_runner` and `bloc_test` were REMOVED — never used. DI is a hand-written `get_it` composition root, JSON is hand-written, `mocktail` is the only mock library.)*
  - 🔐 **Crypto (implemented in Phase 2) — the only real version PIN:** `sodium ^3.4.6` + `sodium_libs ^3.4.6+4`. sodium 4.x requires Dart 3.11+; the project is on Dart 3.10.7 (Flutter 3.38.6) → 4.x cannot be resolved, so 3.x is a deliberate decision (pre-built binaries, no native-assets flag needed; proven by integration tests). ⚠️ `sodium_libs` is tagged **discontinued** on pub — accepted for now because the 3.x line installs working pre-built libsodium binaries; the eventual move to sodium 4.x native assets (once Flutter ships Dart 3.11+) is the exit path. Details in docs/CRYPTO.md.
  - **Deferred major upgrades (NOT pins — no compatibility blocker, each just needs its own migration):** `go_router` 18, `flutter_secure_storage` 11. ✅ **DONE 2026-09-02:** `device_info_plus` 13 + `file_picker` 12 were the one coupled job (`file_picker >=12.1.3` pulls `windows_file_picker` → `win32 ^6.3.0` while `device_info_plus ^12.1.0` required `win32 ^5.11.0`, so neither resolved alone); both are now on 13.2.0 / 12.1.3 (see the pubspec comment and docs/architecture.md §8.1).
  - Minor/patch upgrades were swept on 2026-09-01 (supabase_flutter 2.17.2, mobile_scanner 7.4.0, local_auth 3.0.2, equatable 2.1.0, uuid 4.6.0) — that was a point-in-time sweep, not a standing guarantee: `flutter pub outdated` currently reports one discontinued package (`sodium_libs`, see above) and dozens held back by constraints. Re-sweep before a release rather than assuming the tree is current.
- [x] `core/`: theme (Material 3 light/dark), go_router, DI composition root (`lib/core/di/locator.dart` — hand-written `get_it`; the injectable codegen option was dropped in 2026-09-01, it was never used). ✅
  - [ ] l10n skeleton, Failure types, Supabase client wrapper *(before Phase 3)*.
- [x] go_router base routes (`/`, `/scan`) + screens + redirect guard comment-skeleton. ✅
- [x] CI: `.github/workflows/ci.yml` (2026-09-01) — `push` on `main` + `pull_request`, ubuntu-latest, Flutter 3.38.6 pinned, `flutter analyze --fatal-infos` + `flutter test`. Currently **host 992/992**, analyze clean; **integration 50/50** runs locally only (needs a device/simulator) — measured 2026-09-02 on the audit-follow-ups branch. ✅
  - [x] **DONE (2026-09-02):** the `dart format` gate is now in CI — the repo-wide reformat landed in `7a88a0b` (whitespace only, listed in `.git-blame-ignore-revs`) and a **Format** step (`dart format --output=none --set-exit-if-changed .`) runs before `analyze`. ✅

## Phase 1 — Core OTP engine (serverless, fully working) (weeks 1–2) — COMPLETE
- [x] `core/otp/`: TOTP (RFC 6238), HOTP (RFC 4226), Steam Guard algorithms + Base32 (RFC 4648). ✅
- [x] **Unit tests against RFC test vectors — PASSED** (HOTP Appendix D 10 vectors, TOTP Appendix B 10 vectors SHA1/256/512, Base32, Steam, URI + input validation + VaultCubit id-based + JSON round-trip/robustness + persistence/race). End of Phase 1: 79/79; **after Phase 2 Patch 3 host 122/122; after Patch 4 host 186/186; after Patch 5 (biometrics) host 220/220** (+33: bmk attrs JSON/copyWith, VaultLockCubit biometrics (bootstrap enrolled+deviceAvailable separated, enableBiometric atomic catch→disable, disableBiometric, biometricUnlock unlock-guard exact, KeyMissing→clearBiometric persist + write-fail loop-prevention, **lifecycle inactive-vs-paused: prompt-in-flight exemption**), guard /settings, Settings/UnlockPage widget) (+ integration: enrollBiometric/biometricUnlock round-trip + valid-after-changePassword). Note: automatic reinstall-reset (FirstRunGuard) was added then ROLLED BACK due to review P0 — it would have put an existing user's vault at risk (see CHANGELOG 2026-06-07). ✅
- [x] `otpauth://` URI parse/serialize (`OtpAuthUri`) + round-trip test. ✅
- [x] Vault screen: code cards + countdown ring + copy + manual `otpauth://` adding. ✅
- [x] Stable token `id` (uuid v4) — `OtpAccount.id`, id-based `VaultCubit` + `OtpCard ValueKey` (ARCHITECTURE §7.5 backfill foundation). ✅
- [x] QR scanning (`mobile_scanner` v7) — camera permission flow (iOS `NSCameraUsageDescription` + Android `CAMERA`), double-detection guard, flash/camera switch, permission-denied error UI. ✅
- [x] **Search** in vault (issuer/account/label filter) + HOTP counter persistence (every increment is written to the store). ✅
- [x] Local token storage via `flutter_secure_storage`, **unencrypted** (no master key yet, OS protection only): `VaultRepository` + `OtpAccount` JSON (preserves id/counter), `VaultCubit` `load()` on startup + persist on every mutation. ✅
- [x] **Output:** a real authenticator that works without internet — QR/manual adding, persistent vault, search. ✅

## Phase 2 — E2E crypto layer + encrypt the local vault (weeks 2–3)
> Progress: **Patches 1–5 done** (crypto service, KeyManager, BIP39, encrypted repo, migration; Patch 4: Setup/Unlock/Recovery UI, route guard, lifecycle lock, corruption/integrity UI, DI rewiring, **full UI/UX redesign** per the design system (kept local); **Patch 5: biometric unlock shortcut** — 3rd wrap + OS-keystore access control, Settings, [docs/CRYPTO.md §11](docs/CRYPTO.md)). Details: [docs/CRYPTO.md](docs/CRYPTO.md).
- [x] `core/crypto/`: `CryptoService` interface + libsodium impl — Argon2id (`crypto_pwhash`), XChaCha20-Poly1305 IETF (`crypto_aead_xchacha20poly1305_ietf_*`), key wrap from the same AEAD family. **`crypto_secretbox` NOT USED.** ✅ (Patch 1; sodium 3.4.6+sodium_libs — sodium 4.x requires Dart 3.11+)
- [x] Key hierarchy: masterKey generation, KEK derivation (Argon2id in an isolate), recovery key generation/wrapping (`KeyManager` setup/unlock/recoverUnlock/changePassword). ✅ (Patch 2)
- [x] Round-trip and recovery tests (host 122 + integration 34: encrypt/decrypt/tamper, KEK determinism, BIP39 official Trezor vectors, setup→unlock/recover, changePassword). ✅ (Patch 2)
- [x] **Make the local vault E2E encrypted:** `EncryptedVaultRepository` (token-based record, unchanged-blob + corrupt-record protection, top-level/all-fail integrity), Phase 1→2 `VaultMigration` (commit-marker idempotency, id-based upsert), raw-storage security tests (secret/issuer/accountName do not leak). The vault is now offline+E2E. ✅ (Patch 3)
- [x] Master password setup + recovery key display/verification UI + route guard (based on lock state, its own `CubitRefreshNotifier` adapter — go_router 17.x has no `GoRouterRefreshStream`) + lifecycle lock (paused/inactive) + corruption banner/integrity screen + `/auth-integrity` + `KeyAttributesStore` + `resetVault` + DI/main rewiring (StatefulWidget root, `VaultCubit` after unlock) + **full UI/UX redesign** (embedded Geist/GeistMono, simple-icons CC0, CountdownRing, IssuerAvatar, card/list toggle, tap-to-copy, a11y gates). ✅ (Patch 4; per the design system, kept local)
- [x] On-device biometric-protected master key unlock — **Patch 5 DONE.** 3rd wrap (`biometricEncryptedMasterKey`) + OS-keystore access control (iOS Secure Enclave + `biometryCurrentSet`; Android `strongBiometricOnly` + `enforceBiometrics`), the real gate = `storage.read` (no double prompt), `device_info_plus` API<28 gate, Settings enable/disable + UnlockPage button, lifecycle inactive-vs-paused. Password+recovery always work. ✅ (see [docs/CRYPTO.md §11](docs/CRYPTO.md))

## Phase 3 — Supabase auth + sync (weeks 3–5)
> **DB side COMPLETE and tested** (2026-06-06). Project: `authenticator-dev`. See [supabase/PROJECT_INFO.md](supabase/PROJECT_INFO.md) + [test report](supabase/tests/TEST_REPORT.md). Remaining items depend on the Flutter client.
- [x] DB schema migrations — **all tables** (`tokens`, `key_attributes`, `devices`, `announcements`, `catalog_services`, `audit_logs`, `feature_flags`). ✅
- [x] Order per table: `create table` → **`enable row level security`** → policies → **explicit `grant`**. ✅ (advisor security: 0 warnings)
- [x] `admin_users` + `custom_access_token_hook` + `is_admin()` + all hook permissions **+ `supabase_auth_admin` SELECT policy**. Hook enabled from the Dashboard. ✅ (end-to-end test: admin claim true/false correct)
- [x] `updated_at` trigger (`touch_timestamps`/`touch_updated_at`) + `alter publication supabase_realtime add table tokens`. ✅
- [x] **cross-user RLS test** + with check + audit_logs admin-only + FK cascade. ✅ (8/8 tests passed)
- [x] **Patch 1 — `AuthRepository` (email/password) + registration/login/logout flow.** ✅ Supabase init
  (PKCE), `SessionCubit` (signedIn/out/emailConfirmPending), two-gate guard (identity + vault),
  email confirmation deep-link, signOut→vault lock + network-error-resilient `signedOut`, multi-vault per uid
  (namespace + account-linking + legacy migration `bmk` cleanup). **host 220→257.** *(Flutter)*
- [x] **Patch 2 — `key_attributes` upload/restore + bytea codec.** ✅ Already-encrypted metadata (KDF + KEK/
  recovery-wrapped master key + nonces) backfilled to the server (guarded `unlocked` insert, server-wins) +
  restore on a new device → master password → unlock. `ByteaCodec` (single point), `SupabaseKeyAttributesRepository`,
  `restoring`/`restoreFailed` state + `RestoreFailedPage` (does not fall back to setup on network error). masterKey/KEK/secret/bmk
  NEVER go to the server. **NOT token sync (Patch 3).** **host 257→293.** *(Flutter)*
- [x] **Patch 3 — Encrypted token push/pull + key_attributes UPDATE.** ✅ Token ciphertext/nonce is synced
  with the server (opaque; AAD `token|1|<id>`). Arrival-order LWW (server `updated_at`; per-record `sv` cursor) +
  soft-delete (tombstone) + Realtime as trigger only → REST pull (bytea #1180) + corrupt-row quarantine
  (`safeCursorIso` cap). `RawTokenStore` (raw port without decrypt) + `SupabaseTokenRepository` + `TokenSyncService`.
  **changePassword now performs an UPDATE on `key_attributes`** (`attrs_dirty_v1` retry; masterKey does not change → no token
  re-encryption). Settings live-sync toggle + AppBar indicator. `uid==null` legacy inert. **host 293→347.**
  Real-network round-trip = manual/integration checklist. *(Flutter)*
- [x] **Patch 4 — `devices` record + catalog/feature_flags/announcements reading.** ✅ `devices` register
  (random `device_id` uuid v4, GLOBAL secure storage — NOT hardware-derived; signedIn→register idempotent
  upsert composite PK, resume→`last_seen` heartbeat + 0-row register-fallback; owner-only RLS). Public read
  tables, read-only: `catalog_services` → add-token issuer canonicalization (`IssuerAvatar.slugFor` is shared;
  `logo_url` is IGNORED — offline/privacy); `feature_flags` → **`token_sync_enabled` kill-switch** (gate
  inside `TokenSyncService` → Realtime bypass disabled; `ensureLoaded` cache-ready guarantee; fallback=true; token
  sync ONLY — `key_attributes` EXCLUDED); `announcements` → read-only Settings section (`audience` client-filtered).
  NO Realtime → fetch-on-signedIn + global cache + offline fallback. **Cross-account correlation tradeoff
  documented** (same device/multiple accounts → same device_id; accepted). Server schema unchanged; E2E untouched;
  legacy/test paths exact via optional params. **host 347→413.** Real-network round-trip = manual/integration
  checklist. *(Flutter)* → **Phase 3 DONE**
- [x] App lock (biometric) feature — **completed in Phase 2 Patch 5.** ✅

## Phase 3.5 — CI, dependency cleanup, hardening (2026-09-01) — DONE
> Infrastructure + security hardening between Phase 3 and Phase 4. **NO crypto routine, NO server schema, NO sync-protocol change.**
> host **436/436 → 454/454**, `flutter analyze --fatal-infos` clean. Details: [CHANGELOG 2026-09-01](CHANGELOG.md).
- [x] **GitHub Actions CI** (`.github/workflows/ci.yml`): push on `main` + pull_request, ubuntu-latest, `subosito/flutter-action@v2` pinned to Flutter 3.38.6 stable + cache → `pub get` / `analyze --fatal-infos` / `test`; concurrency group cancels superseded runs. Integration tests excluded (device required). ✅
- [x] **8 unused packages dropped** (`injectable`, `injectable_generator`, `freezed`, `freezed_annotation`, `json_annotation`, `json_serializable`, `build_runner`, `bloc_test`) — zero imports, no generated files, no `build.yaml`. DI stays hand-written `get_it`; JSON stays hand-written; `mocktail` kept. Minor/patch upgrades applied; `sodium` 3.x pin and the deferred go_router/secure_storage/device_info_plus majors untouched. ✅
- [x] **Supabase config fail-fast:** embedded URL/publishable-key fallbacks REMOVED from `SupabaseConfig`; `validate()` + `ensureConfigured()` run in `main.dart` before `Supabase.initialize` → a missing/invalid `--dart-define` throws a `StateError` in debug **and** release. `env/dev.example.json` committed, `env/*.json` gitignored; run with `--dart-define-from-file=env/dev.json`. ✅
- [x] **Ref-counted screen-capture protection:** `SecureScreen.acquire()/release()` (Dart-side counter — the native side is last-caller-wins, so nested sensitive screens used to disable protection too early) + `SecureScreenScope` widget. Protected at the time: vault, unlock, setup_password, recovery_unlock, recovery_show, recovery_verify (login/register followed in the same review; scan/import/export in Phase 5 — see Phase 7). ✅
- [ ] **Open:** iOS still cannot block screenshots/recording (only the background snapshot is hidden). *(The `dart format` CI gate — **DONE (2026-09-02):** repo reformatted in `7a88a0b`, blame-ignored via `.git-blame-ignore-revs`, and a **Format** step added to `ci.yml` before `analyze`.)*

## Phase 4 — Social sign-in + push *(once developer accounts are ready)*
- [ ] Google Sign-In + Apple Sign-In (added to `AuthRepository`, core unchanged).
- [ ] FCM setup (Firebase project + APNs certificate).
- [ ] Device push token registration (`devices`) + admin→push Edge Function.

## Phase 5 — Import/Export + service catalog (weeks 5–6) — DONE
> **Patch 1 (2026-09-02) — DONE:** Aegis + 2FAS import and the encrypted backup export.
> **Patch 2 (2026-09-02) — DONE:** Google Authenticator transfer-QR import (hand-written protobuf decoder,
> multi-QR batch collector, migration mode inside the existing `ScanPage`).
> **Patch 3 (2026-09-02) — DONE:** tags (`OtpAccount.tags` inside the encrypted blob; Aegis/2FAS groups mapped
> onto them), migration import from a **pasted link** and from a **saved QR image**.
> **NO server schema change, NO new crypto primitive** in any of the three — not even a record-version or AAD
> change for tags. Details: [CHANGELOG 2026-09-02](CHANGELOG.md).
- [x] **Import: Aegis, 2FAS** ✅ (Patch 1, 2026-09-02) — plain-JSON Aegis (`db`/`header`) and 2FAS schema v4, format
  auto-detection, tolerant per-entry skipping (the file never fails as a whole), Base32-canonicalizing dedupe key,
  preview → confirm → single `VaultCubit.addAll`.
- [x] **Import: Google Authenticator** ✅ (Patch 2, 2026-09-02) — `otpauth-migration://` transfer QR: hand-written
  protobuf wire decoder (no codegen; proto3 field presence is what keeps a counter-less HOTP entry from being
  imported with a guessed 0), multi-QR batch collector (any scan order, a foreign `batch_id` is never merged,
  partial import allowed), migration mode inside the existing `ScanPage` — no new route, no guard or DI change.
- [x] **Export (encrypted backup)** ✅ (Patch 1, 2026-09-02) — own `projectauth-backup` v1 envelope, Argon2id +
  XChaCha20-Poly1305 through the existing `CryptoService`, KDF parameters bound into the AAD. The backup password is
  independent of the master password.
- [x] **Issuer logo/matching via `catalog_services`** ✅ — already delivered in Phase 3 Patch 4 (issuer canonicalization;
  `logo_url` is deliberately ignored for offline/privacy).
- [x] **Tag/folder organization** ✅ (Patch 3, 2026-09-02) — `OtpAccount.tags` (≤8 labels, ≤32 runes each) INSIDE
  the encrypted blob: no record-version bump, no AAD change, no backup-envelope change, and the key is omitted
  when empty so an untagged vault serializes byte-identically to before. Vault-wide rename/delete with one persist
  and one push each, a session-scoped single-selection filter strip, and a metadata-only edit sheet that cannot
  touch the secret. Aegis `db.groups` (uuid refs + the legacy singular `group`) and 2FAS `groups`/`groupId` are
  now mapped onto tags; Google's payload has no grouping field at all. Tags are deliberately NOT part of
  `dedupeKey` — moving a token between groups must not make it look like a new token.
- [x] **Import a migration QR from a pasted link or a saved QR image file** ✅ (Patch 3, 2026-09-02) — the pasted
  `otpauth-migration://` link goes through `AddTokenSheet` (the same `MigrationScanController`, progress band and
  shared preview as the camera path; the clipboard is never read programmatically), and "Görüntüden oku" in
  `ScanPage` decodes a saved screenshot through `MobileScannerPlatform.analyzeImage` — which needs no camera and
  no camera permission, so it is the only working route on a device where the camera is broken or denied. The
  picker's plaintext copy is zero-filled and unlinked before the general cache sweep
  ([docs/CRYPTO.md §16.5](docs/CRYPTO.md)); the user's original image is never touched. **Not supported on the
  iOS Simulator or the web** (the plugin has no Vision/ML Kit path there) — the UI says so distinctly instead of
  blaming the image.
- [x] **`device_info_plus` 13 + `file_picker` 12 coupled upgrade** (2026-09-02). The 11.x hold existed only because
  `file_picker >=12.1.3` pulls `windows_file_picker` → `win32 ^6.3.0` while `device_info_plus ^12.1.0` required
  `win32 ^5.11.0`; raised together they resolve (13.2.0 / 12.1.3). `DocumentPort` migrated to the federated 12.x API
  (`pickFile()` → `PlatformFile.readAsBytes()`, `saveFile()` → `Uri?`). Drops `DKImagePickerController` /
  `DKPhotoGallery` / `SDWebImage` / `SwiftyGif` from `ios/Podfile.lock`; costs iOS deployment target 13.0 → 14.0
  (same device set).

## Phase 6 — Admin panel (Next.js) (can start in parallel, once the tables are ready in Phase 3) — MVP DONE (2026-09-02)
> Standalone npm package under `admin/`: own lockfile, own CI workflow (`.github/workflows/admin-ci.yml`), **not**
> part of the Flutter `analyze`/`test` pipeline. **NO Dart change, NO crypto change, NO server schema change** —
> the one SQL file added (`20260902201638_admin_backend_role.sql`) only creates a DB role and its grants.
> admin **153/153** (vitest), Flutter host **1188/1188** unchanged. Details:
> [CHANGELOG 2026-09-02](CHANGELOG.md) and [admin/README.md](admin/README.md).
- [x] **Next.js + Supabase SDK + shadcn/ui + admin claim middleware (`app_metadata.admin`)** ✅ (2026-09-02) —
  Next.js 16.3.4 App Router, `@supabase/ssr` 0.12.5, supabase-js 2.114.0, Tailwind 4 + shadcn/ui, zod 4, exact
  version pins. The claim check lives in **`src/proxy.ts`** — Next.js 16 renamed the `middleware` file convention
  to `proxy` — and is a **first line only**: every privileged handler re-checks with `requireAdmin()`, which
  verifies the JWT against the project's JWKS via `auth.getClaims()` and demands a literal
  `app_metadata.admin === true`.
- [x] **Prerequisite — backend DB role** ✅ **applied to the live project 2026-09-02.**
  `supabase/migrations/20260902201638_admin_backend_role.sql` creates the NOLOGIN privilege carrier
  `admin_backend` with `usage` on `private` + `execute` on `private.admin_global_stats()` (Pattern B), and
  re-revokes both from `public`/`anon`/`authenticated`. It contains **no password**. Live state, verified on
  2026-09-02 against `vfyqokvgtdxxurroqbtj`: the migration is applied (DB version `20260902201638`,
  `list_migrations` matching the repo's four files), `admin_backend` exists NOLOGIN + NOINHERIT with exactly
  those two grants and **no table privileges**, and the login role `admin_app` exists as a member of it with
  no `bypassrls`/`superuser`/`createrole`; `has_table_privilege` for `select` on `public.tokens` and
  `public.key_attributes` is **false** for both roles. **`admin_app`'s password was set by the operator on 2026-09-02** in the
  Dashboard SQL editor (`alter role admin_app password '<güçlü-parola>';`, deliberately never done by an agent
  or written into a migration), and the role is now `DATABASE_URL`. Path (a) was smoke-tested live the same
  day: pooler 6543 + 5432 with verified TLS, `set local role admin_backend` → `private.admin_global_stats()`
  returned counts, `select count(*) from public.tokens` → `42501 permission denied`. A password **rotation is
  recommended** (it was transmitted in a chat).
- [x] **Reading** ✅ (2026-09-02)
  - Admin-public tables (`announcements`, `catalog_services`, `feature_flags`) and `audit_logs` are read with the
    admin's **own session** (path (c)) — `audit_logs` under the RLS policy `to authenticated using (public.is_admin())`.
    The secret key is deliberately not used for reads.
  - **Two access paths, never mixed:** (a) cross-user aggregate read → `private.admin_global_stats()` over a
    **direct Postgres connection** (`src/lib/db.ts`: `begin; set local role admin_backend; select …; commit`,
    `prepare: false` so both pooler ports work). (b) `auth.admin`/REST operations → **secret key**
    (`src/lib/supabase/admin.ts`). The `private` schema is not exposed to the Data API, so (a) cannot be an `.rpc()`.
  - Guardrails as designed: private schema + `set search_path=''` + `revoke execute from public/anon/authenticated`
    + `grant execute` only to `admin_backend`. See ARCHITECTURE §6.
- [x] **Writes/privileged operations server-side + secret key** ✅ (2026-09-02) — implemented as Next.js **Server
  Actions** (no Edge Function: one server-side execution environment, one place the secret key lives).
  - [x] User suspension/deletion (`auth.admin.updateUserById` with `ban_duration` / `deleteUser`) — server-side
    guards that fail closed: not yourself, not another admin, and an unreadable `admin_users` list **throws**
    instead of defaulting to empty. The delete dialog states the FK cascade (tokens/key_attributes/devices go
    with the account, unrecoverably — nobody else ever held the key).
  - [x] `audit_logs` insert; **every** privileged operation writes exactly one row in the handler that performed
    it, with `actor` from `requireAdmin()` and never from the request body. A failed audit write is reported as
    a failed **audit write**, not as a failed operation.
  - [x] Announcement CRUD (`audience ∈ {all, flutter, android, ios}` — the enum the Flutter client filters on;
    anything else would be silently invisible on every device).
  - [ ] **FCM push triggering — NOT done, moved to Phase 4 by dependency.** Sending a push needs the Firebase
    project, the APNs certificate and the `devices` push-token registration, all of which are Phase 4 items
    blocked on the developer accounts. The announcement rows the push would carry already exist.
- [x] **Key terminology** ✅ — the panel accepts **only** the new keys: `src/lib/env.ts` requires the
  `sb_publishable_…` / `sb_secret_…` prefixes and rejects a legacy `eyJ…` JWT anon/service_role key outright.
  Validation is lazy (request-time), so `next build` and CI need no secrets. The `apikey`-not-`Bearer` rule is
  handled inside supabase-js 2.114.0 (`isNewApiKey()`), so no header is set by hand; no Edge Function, so no
  `verify_jwt=false` to set. See ARCHITECTURE §6.
- [x] **Service catalog CRUD; `feature_flags` management; audit log viewing** ✅ (2026-09-02) — catalog with
  `https://`-only `logo_url` validation (the column is publicly readable, so a `javascript:`/`data:` value would
  be a stored payload for any future client that renders it); flags with a **delete-proof** `token_sync_enabled`
  (a missing row makes clients assume sync is ON, so deleting it is the opposite of disabling it) plus a
  confirmation on disable and an 8 KiB JSON-object payload cap; `/audit` read-only, 50/page, action whitelist
  and a LIKE-escaped `?q=`.
- [ ] **Open (deliberate MVP limits):** user search is page-local (`auth.admin.listUsers` has no server-side
  email filter); `/announcements`, `/catalog`, `/flags` fetch the whole table with no pagination; no growth
  charts (a histogram needs a new `security definer` function); no admin-management UI (granting admin stays a
  SQL step on `public.admin_users`, on purpose); no Playwright/e2e suite — the flows are covered by the manual
  smoke checklist in admin/README.md §7.

## Phase 7 — Hardening & release
- [~] Security review (key lifecycle, memory wiping, screenshot blocking) — **key lifecycle + memory wiping DONE 2026-09-02**, screenshot blocking still partial.
  - **Key lifecycle + memory wiping ✅ (2026-09-02).** Read-only review of `lib/core/crypto/**`, `lib/features/auth|account|vault|import_export/**`, `main.dart` and the DI, verified against the installed package sources; 2 P1 + 6 P2 + 6 P3 raised and **all fixed the same day**. The two P1s: a non-interactive sign-out (gotrue refresh failure, server-side revocation, expiry, global sign-out from another device) never closed the E2E gate, so the master key stayed resident and re-login as the same uid walked into a still-unlocked vault on the *account* password alone; and `flutter_secure_storage`'s Android `resetOnError: true` default silently deleted `vault_key_attributes_v1` on a decrypt failure — with an Android device-to-device transfer as a concrete trigger — turning an existing vault into a fresh setup screen. Full list and rationale: [CHANGELOG 2026-09-02 (Phase 7)](CHANGELOG.md); design: [docs/CRYPTO.md](docs/CRYPTO.md) §3, §9.1–§9.3, §11, §16.5, §17 and the new **§18 (Dart/Flutter limits — what "wiping" can and cannot mean)**. host **1188 → 1254**; no schema, AAD or backup-format change.
  - **Screenshot blocking — partial (2026-09-01), unchanged.** Ref-counted `SecureScreen` on **11** sensitive screens — vault, unlock, setup_password, recovery_show/verify/unlock, login, register (the last two added in the review follow-ups), scan (Phase 5 Patch 2) and import/export (Phase 5 Patch 1). `grep -rn "SecureScreenScope(" lib/` is the authoritative list. **Still open:** iOS has no FLAG_SECURE equivalent → screenshots/recording are NOT blocked there (only the recents/background snapshot is hidden).
- [ ] **Foreground idle auto-lock** (raised as P3-4 by the 2026-09-02 review, deliberately not folded into it). The lock model is background-only (`onAppBackgrounded`) plus the interactive lock, so an unlocked vault left on screen stays unlocked indefinitely. That matches what is documented — not a broken invariant — but it is table stakes for an authenticator. It must reuse `lock(immediate: true)` (the synchronous dispose path, which since the review also runs the registered plaintext holders) and **respect the §17 system-file-flow exemption**: the picker runs in another process, so the app is legitimately `paused`/idle while the user chooses a file. Needs a timeout setting and an activity signal, which is why it is a feature item rather than a review fix.
- [ ] **In-app change-master-password in Settings** (raised as P3-5 by the same review). `KeyManager.changePassword` is today reachable **only** through the recovery-mnemonic flow (`recoverWithNewPassword`), so a user who believes their master password is compromised must produce the 24 words to rotate it. The crypto is cheap (no token re-encryption — only a new salt + KEK + `encryptedMasterKey`, [docs/CRYPTO.md §13](docs/CRYPTO.md)) and the server-update plumbing (`_syncAttrsAfterPasswordChange` + the `attrs_dirty_v1` retry marker) already exists; **only the Settings UI is missing** — current password → new password (same `KeyManager` policy) → confirm, plus the biometric re-wrap decision.
- [ ] **Supabase leaked-password protection** — enable the HaveIBeenPwned check on the `authenticator-dev` project (Auth → Policies): the *login* password is the only credential the server sees, and it is currently accepted even if it appears in a known breach corpus. Does not touch the E2E model (the master password never reaches the server, so no server-side check is possible or wanted for it).
- [x] **iOS release-build check — `NSPhotoLibraryUsageDescription`** — closed twice over, and the second pass reversed the conclusion of the first. **(1) The `PICKER_MEDIA=false` workaround this item originally proposed is dead:** the `file_picker` 12 upgrade (2026-09-02) moved iOS into `file_picker_darwin`, which depends on Flutter alone, so `DKImagePickerController/PhotoGallery` (→ `SDWebImage`, `SwiftyGif`) left `ios/Podfile.lock` — a document-only build links no photo-library API at all, with no flag needed. **(2) Phase 5 Patch 3 then made the app pick images on purpose** ("Görüntüden oku" in `ScanPage`), so `ios/Runner/Info.plist` now DOES declare `NSPhotoLibraryUsageDescription`, and that is the correct end state — the earlier "keep it out" instruction no longer applies. Note it is declared for **review**, not for a prompt: `file_picker_darwin` picks through PHPicker, which hands over one photo without the app holding library access, so iOS shows no permission dialog. The string keeps App Review from asking about an image-picking app, and keeps the prompt from being string-less if the plugin ever falls back to the older picker. `Info.plist` declares exactly three usage strings today (`NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, `NSFaceIDUsageDescription`) and no write-access key — the app never writes to the photo library.
- [ ] **iOS release-build check — keep `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` OUT of `ios/Runner/Info.plist`.** Either key exposes the app's own Documents directory in Files, which lets the user pick it as the export destination — and `FilePickerDocumentPort` shreds a leftover in exactly that directory after `saveFile`. The shredder compares paths and backs off, but that is the second line of defence; adding either key means revisiting `_shredIosSaveLeftover` first. See [docs/CRYPTO.md §16.5](docs/CRYPTO.md).
- [ ] Accessibility, language support, store materials.
- [ ] App Store / Play Store release (Apple developer account required).

---

## Dependency timeline (critical path)
```
Phase 0 → Phase 1 → Phase 2 → Phase 3 ─┬─► Phase 5 ─► Phase 7
                                        └─► Phase 6 (admin, parallel) — MVP DONE 2026-09-02; FCM push waits on Phase 4
Phase 4 (social+push) ── plugs in at any point once developer accounts are ready
```

## Current blockers / user action
- [x] **Open a Supabase project** ✅ — `authenticator-dev` created, migration applied, hook enabled.
- [ ] Google Play + Apple Developer accounts (for Phase 4 and release — Phases 0–3 progress while waiting).
- [ ] Firebase project (for Phase 4 push).
- [~] (Before Phase 6) Backend DB role + `private` schema grant (for the admin aggregate call) — **migration applied to `authenticator-dev` on 2026-09-02** (`supabase/migrations/20260902201638_admin_backend_role.sql`, live DB version `20260902201638`), and **both roles now exist**: `admin_backend` (NOLOGIN, NOINHERIT, `private` USAGE + `admin_global_stats()` EXECUTE, no table privileges) and `admin_app` (LOGIN, member of `admin_backend`), with `select` on `public.tokens`/`public.key_attributes` false for both. The **Postgres CA is bundled** at `admin/certs/supabase-prod-ca-2021.crt` (+ `admin/certs/README.txt`), and the pooler handshake against it verifies (`Verify return code: 0 (ok)`, 2026-09-02). The **`admin_app` password was set on 2026-09-02** and that role is in `DATABASE_URL`; path (a) was smoke-tested live the same day (pooler 6543 + 5432, verified TLS, `set local role admin_backend` → `admin_global_stats()` returned counts, `select count(*) from public.tokens` → `42501`). **Left for the operator:** paste the `sb_secret_…` key into `admin/.env.local` (and, recommended, rotate the `admin_app` password — it was transmitted in a chat). One canonical list of everything still pending: [supabase/PROJECT_INFO.md → Bekleyen operatör adımları](supabase/PROJECT_INFO.md#bekleyen-operatör-adımları-operator-todo).
- [ ] (Before Phase 6) First **real** admin row — still open as of 2026-09-02: `auth.users` holds only a UI-test account (`uitest…@gmail.com`), so no real account exists to promote. Register one in the mobile app, then `insert into public.admin_users (user_id) values ('<uuid>');` — without a row nobody gets past the panel's `/login`. See the canonical list: [supabase/PROJECT_INFO.md → Bekleyen operatör adımları](supabase/PROJECT_INFO.md#bekleyen-operatör-adımları-operator-todo).

## Open design decisions (to be clarified later)
- Conflict resolution starts with **arrival-order LWW** (the last to reach the server wins; see ARCHITECTURE §5); for heavy multi-device usage a move to CRDT/true-modified-time can be evaluated.
- **Tag operations widen the LWW conflict radius from 1 record to N (risk R3, Phase 5 Patch 3).** `renameTag`/`deleteTag` rewrite every token carrying the tag, so one gesture dirties N records (in a single persist and a single push, but still N rows on the wire). Under arrival-order LWW a concurrent edit of any one of those N tokens on another device can lose that device's change for that record — where before Patch 3 a user action touched one token at a time. Accepted for now: the operation is rare, deliberate and idempotent, and the loss window is the ordinary sync round trip. Revisit **together with** the LWW decision above, not separately — the candidate fixes are the same `client_modified_at`/`revision` extension, plus possibly a field-level merge so a tag rename and a name edit on the same token stop overwriting each other.
- Recovery key format: BIP39 word list or hex? (Decide via UX testing.)
- Admin analytics metrics are metadata-only because of E2E; the exact full list of which metrics will be clarified.
