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
  - **Deferred major upgrades (NOT pins — no compatibility blocker, each just needs its own migration):** `go_router` 18, `flutter_secure_storage` 11, `device_info_plus` 13. Minor/patch upgrades are kept current (2026-09-01: supabase_flutter 2.17.2, mobile_scanner 7.4.0, local_auth 3.0.2, equatable 2.1.0, uuid 4.6.0).
- [x] `core/`: theme (Material 3 light/dark), go_router, DI composition root (`lib/core/di/locator.dart` — hand-written `get_it`; the injectable codegen option was dropped in 2026-09-01, it was never used). ✅
  - [ ] l10n skeleton, Failure types, Supabase client wrapper *(before Phase 3)*.
- [x] go_router base routes (`/`, `/scan`) + screens + redirect guard comment-skeleton. ✅
- [x] CI: `.github/workflows/ci.yml` (2026-09-01) — `push` on `main` + `pull_request`, ubuntu-latest, Flutter 3.38.6 pinned, `flutter analyze --fatal-infos` + `flutter test`. Currently **host 454/454**, analyze clean; **integration 38/38** runs locally only (needs a device/simulator). ✅
  - [ ] A `dart format` gate is deliberately NOT in CI yet — **known debt:** most of the tree is not format-clean, so enabling it means a repo-wide reformat commit first.

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
- [x] **Ref-counted screen-capture protection:** `SecureScreen.acquire()/release()` (Dart-side counter — the native side is last-caller-wins, so nested sensitive screens used to disable protection too early) + `SecureScreenScope` widget. Protected: vault, unlock, setup_password, recovery_unlock, recovery_show, recovery_verify. ✅
- [ ] **Open:** iOS still cannot block screenshots/recording (only the background snapshot is hidden). A `dart format` CI gate is still off (repo not format-clean).

## Phase 4 — Social sign-in + push *(once developer accounts are ready)*
- [ ] Google Sign-In + Apple Sign-In (added to `AuthRepository`, core unchanged).
- [ ] FCM setup (Firebase project + APNs certificate).
- [ ] Device push token registration (`devices`) + admin→push Edge Function.

## Phase 5 — Import/Export + service catalog (weeks 5–6)
> **Patch 1 (2026-09-02) — DONE:** Aegis + 2FAS import and the encrypted backup export.
> **NO server schema change, NO new crypto primitive.** Details: [CHANGELOG 2026-09-02](CHANGELOG.md).
- [x] **Import: Aegis, 2FAS** ✅ (Patch 1, 2026-09-02) — plain-JSON Aegis (`db`/`header`) and 2FAS schema v4, format
  auto-detection, tolerant per-entry skipping (the file never fails as a whole), Base32-canonicalizing dedupe key,
  preview → confirm → single `VaultCubit.addAll`.
- [ ] Import: **Google Authenticator** (migration protobuf payload) → **Patch 2**.
- [x] **Export (encrypted backup)** ✅ (Patch 1, 2026-09-02) — own `projectauth-backup` v1 envelope, Argon2id +
  XChaCha20-Poly1305 through the existing `CryptoService`, KDF parameters bound into the AAD. The backup password is
  independent of the master password.
- [x] **Issuer logo/matching via `catalog_services`** ✅ — already delivered in Phase 3 Patch 4 (issuer canonicalization;
  `logo_url` is deliberately ignored for offline/privacy).
- [ ] Tag/folder organization → **Patch 3** (this patch deliberately does not read Aegis/2FAS `groups`).
- **Deps note:** `file_picker` is held at **^11.0.3**. `file_picker >=12.1.3` pulls `windows_file_picker` → `win32 ^6.3.0`,
  while `device_info_plus ^12.1.0` requires `win32 ^5.11.0` → the 12.x line does not resolve. 11.0.3 has the same
  `withData` / `saveFile(bytes:)` API.

## Phase 6 — Admin panel (Next.js) (can start in parallel, once the tables are ready in Phase 3)
- [ ] Next.js + Supabase SDK + shadcn/ui + admin claim middleware (`app_metadata.admin`).
- [ ] **Reading:**
  - Admin-public tables (`announcements`, `catalog_services`, `feature_flags`) → normal `authenticated` client.
  - **Two access paths (do not mix):** (a) cross-user **reading** → a `security definer` aggregate function in a private schema via a server-side **direct Postgres connection** (`DATABASE_URL`/pooler + DB role) (returns counts/metadata, not raw rows). (b) `auth.admin`/REST operations → **secret key** (REST API identity, not a DB connection). The secret key does not call the DB function directly.
  - **Cross-user reading** cannot be done from the client because of RLS `user_id=auth.uid()`, and since the private schema is not exposed to the Data API it cannot be called via `supabase-js .rpc()` either → path (a). Guardrails: private schema + `set search_path=''` + `revoke execute from public/anon/authenticated` + `grant execute` only to the backend DB role. See ARCHITECTURE §6.
- [ ] **Writes/privileged operations server-side via route handler / Edge Function + secret key** (the secret key is not embedded in the browser):
  - User suspension/deletion (`auth.admin` API).
  - `audit_logs` insert; every privileged operation is logged.
  - Announcement CRUD + FCM push triggering.
- [ ] **Key terminology:** in a new project, client → publishable key, backend → secret key (legacy `anon`/`service_role` are being deprecated by the end of 2026 — use the new ones from the start). The new secret key in Edge Functions/HTTP uses the **`apikey` header**, NOT `Bearer` (otherwise `Invalid JWT` 401); set `verify_jwt=false` on the relevant function. See ARCHITECTURE §6.
- [ ] Service catalog CRUD; `feature_flags` management; audit log viewing.

## Phase 7 — Hardening & release
- [~] Security review (key lifecycle, memory wiping, screenshot blocking) — **screenshot blocking partially done 2026-09-01** (see [CHANGELOG](CHANGELOG.md)): ref-counted `SecureScreen` on the 8 sensitive screens (login/register added in the review follow-ups). **Still open:** iOS has no FLAG_SECURE equivalent → screenshots/recording are NOT blocked there (only the recents/background snapshot is hidden). Key lifecycle + memory wiping review not yet done.
- [ ] Accessibility, language support, store materials.
- [ ] App Store / Play Store release (Apple developer account required).

---

## Dependency timeline (critical path)
```
Phase 0 → Phase 1 → Phase 2 → Phase 3 ─┬─► Phase 5 ─► Phase 7
                                        └─► Phase 6 (admin, parallel)
Phase 4 (social+push) ── plugs in at any point once developer accounts are ready
```

## Current blockers / user action
- [x] **Open a Supabase project** ✅ — `authenticator-dev` created, migration applied, hook enabled.
- [ ] Google Play + Apple Developer accounts (for Phase 4 and release — Phases 0–3 progress while waiting).
- [ ] Firebase project (for Phase 4 push).
- [ ] (Before Phase 6) Backend DB role + `private` schema grant (for the admin aggregate call).

## Open design decisions (to be clarified later)
- Conflict resolution starts with **arrival-order LWW** (the last to reach the server wins; see ARCHITECTURE §5); for heavy multi-device usage a move to CRDT/true-modified-time can be evaluated.
- Recovery key format: BIP39 word list or hex? (Decide via UX testing.)
- Admin analytics metrics are metadata-only because of E2E; the exact full list of which metrics will be clarified.
