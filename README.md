# Authenticator App

End-to-end (E2E) encrypted, multi-device synchronized **TOTP/HOTP authenticator** — similar to Ente Auth / Google Authenticator.

- **Mobile:** Flutter (iOS + Android), MVVM + Bloc, go_router, feature-first architecture
- **Backend:** Supabase (Auth + Postgres + Realtime + RLS)
- **Admin panel:** Next.js / React (Phase 6)
- **Encryption:** E2E — TOTP secrets are encrypted on-device with libsodium (XChaCha20-Poly1305 + Argon2id); the server only ever sees an opaque blob.

> **Security essence:** Under no circumstances can the server (Supabase) see a plaintext TOTP secret. The decryption key lives only on the user's device and in their master password.

---

## Documentation map

| File | Contents |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Full architecture: security/crypto model, layers, Supabase schema + RLS, admin panel, auth flow, sync, testing strategy |
| [PLAN.md](PLAN.md) | Phased roadmap (Phase 0–7), dependency timeline, status |
| [supabase/PROJECT_INFO.md](supabase/PROJECT_INFO.md) | Live Supabase project: URL, publishable key, deployment checklist |
| [supabase/migrations/](supabase/migrations/) | Runnable SQL migrations |
| [supabase/tests/TEST_REPORT.md](supabase/tests/TEST_REPORT.md) | Security & RLS test report (end-to-end, passed) |
| [supabase/tests/security_rls_tests.sql](supabase/tests/security_rls_tests.sql) | Re-runnable security test script |
| [docs/architecture.md](docs/architecture.md) | Runtime view: feature→screen→state map, the two state layers, route/guard matrix, dependency list |
| [docs/CRYPTO.md](docs/CRYPTO.md) | Crypto design: primitives, key hierarchy, AAD scheme, password policy, biometrics, sync envelopes, screen-capture protection |
| [docs/OTP_ENGINE.md](docs/OTP_ENGINE.md) | OTP core (TOTP/HOTP/Steam/Base32) technical note + RFC test status |
| [CHANGELOG.md](CHANGELOG.md) | Version/progress log |

---

## Current status (2026-09-01)

| Stage | Status |
|---|---|
| Architecture & plan | ✅ Matured (multi-round review + verification) |
| Supabase backend (Phase 3 DB) | ✅ Implemented + clean security scan (0 warnings) + end-to-end tests (8/8) + least-privilege hardening (0003) |
| Custom Access Token Hook | ✅ Enabled + admin claim verified |
| Flutter — Phase 0 skeleton | ✅ Project + feature-first structure + DI/router/theme + dependencies |
| Flutter — Phase 1 OTP core | ✅ TOTP/HOTP/Steam/Base32 + `otpauth://` (validated, stable token id) + vault UI + QR scanning (mobile_scanner) + secure_storage persistence + search · `analyze` clean |
| Flutter — Phase 2 E2E crypto (Patches 1–3) | ✅ `CryptoService`/SodiumSumo (XChaCha20-Poly1305 IETF + Argon2id), `KeyManager` (setup/unlock/recovery/changePassword), in-house BIP39 (MIT, official vectors), `EncryptedVaultRepository` (token-based, unchanged-blob + corrupt-record protection, integrity), Phase 1→2 migration (commit-marker, upsert) · **host 122/122 + integration 34/34** (sim; the integration suite is **38** today) |
| Flutter — Phase 2 UI/session (Patch 4) | ✅ Setup/Unlock/Recovery UI + route guard (based on lock state) + lifecycle lock (paused/inactive) + corruption banner/integrity screen + `KeyAttributesStore`/`resetVault` + DI/main rewiring + **full UI/UX redesign** (embedded Geist/GeistMono, simple-icons CC0, CountdownRing, IssuerAvatar, card/list toggle, tap-to-copy, a11y) · **host 186/186** · per the design system (kept local) |
| Flutter — Phase 2 biometrics (Patch 5) | ✅ Biometric unlock shortcut: 3rd wrap (`biometricEncryptedMasterKey`) + OS-keystore access control (iOS Secure Enclave + `biometryCurrentSet`, Android `strongBiometricOnly`+`enforceBiometrics`), the real gate = `storage.read` (no double prompt; `local_auth` for availability only), Settings enable/disable + UnlockPage button, `device_info_plus` API<28 gate, lifecycle inactive-vs-paused distinction, password+recovery always work · **host 220/220** · see [docs/CRYPTO.md §11](docs/CRYPTO.md) |
| Flutter — Phase 3 auth (Patch 1) | ✅ Supabase email/password identity (registration/login/logout + email confirmation, PKCE deep-link). Two-gate guard (identity OUTERMOST → vault lock), `unknown→/splash` (no masterKey crash), `onAuthStateChange` `onError` (crash prevention), signOut → vault lock + network-error-resilient `signedOut`, multi-vault per uid (namespace + account-linking + legacy `bmk` cleanup). Login password ≠ master password. **NO sync yet (Patches 2–3).** · **host 257/257** |
| Flutter — Phase 3 sync (Patch 2) | ✅ `key_attributes` upload/restore (already-encrypted KDF + KEK/recovery-wrapped master key). On a new device, Supabase login → pull from cloud → master password → unlock. `ByteaCodec` (single point for bytea↔Uint8List), guarded `unlocked` insert on upload (server-wins), `restoring`/`restoreFailed` state: while fetching shows `/splash` (does not fall back to setup), network error gets a separate screen. **masterKey/KEK/secret/bmk NEVER go to the server.** Server schema unchanged. **NO token sync yet (Patch 3).** · **host 293/293** |
| Flutter — Phase 3 token sync (Patch 3) | ✅ Encrypted token push/pull + soft-delete (tombstone) + arrival-order LWW (server `updated_at`; per-record `sv` cursor). `RawTokenStore` (raw port without decrypt) + `SupabaseTokenRepository` + `TokenSyncService`. Realtime = trigger only → REST pull (bytea #1180); corrupt-row quarantine (`safeCursorIso` cap). **changePassword now performs an UPDATE on `key_attributes`** (`attrs_dirty_v1` retry marker); masterKey does not change → no token re-encryption. Settings live-sync toggle + AppBar sync indicator. **Only opaque ciphertext/nonce goes to the server; the `uid==null` legacy path is inert.** · **host 347/347** |
| Flutter — Phase 3 devices+catalog (Patch 4) | ✅ `devices` record (random `device_id` uuid v4, GLOBAL; signedIn→register, resume→`last_seen` heartbeat + 0-row register-fallback; owner-only RLS). Public read tables (read-only): `catalog_services` → add-token issuer canonicalization (`logo_url` is IGNORED — offline/privacy), `feature_flags` → **`token_sync_enabled` kill-switch** (gate inside `TokenSyncService` → Realtime bypass disabled; `ensureLoaded` cache-ready; fallback=true; token sync ONLY — key_attributes excluded), `announcements` → read-only Settings section (`audience` client-filtered). NO Realtime → fetch+cache. **Cross-account correlation tradeoff documented.** Server schema unchanged; E2E untouched. · **host 413/413** |
| Flutter — Phase 3.5 hardening | ✅ Security review fixes (release manifest + Auto Backup off, master password **min 12 + ≥3 character classes**, conditional clipboard auto-clear, `resetVault` server tombstone cleanup + `ResetPendingStore` retry, strict `OtpAccount.fromJson`), **ref-counted `SecureScreen`/`SecureScreenScope`** on vault/unlock/setup/recovery, Supabase config **fail-fast** (embedded fallbacks removed, `--dart-define` only), 8 unused codegen/test packages dropped + minor upgrades, **GitHub Actions CI** · **host 454/454** |
| Flutter — Phase 5 Patch 1 (import/export) | ✅ (2026-09-02) Aegis (plain JSON) + 2FAS (schema v4) import: format auto-detection, tolerant per-entry skipping, Base32-canonicalizing dedupe key, preview → confirm → single `VaultCubit.addAll`. **Encrypted backup export** (`projectauth-backup` v1: Argon2id + XChaCha20-Poly1305 through the existing `CryptoService`, KDF parameters bound into the AAD, backup password independent of the master password). `file_picker ^11.0.3` `DocumentPort`, `/import` `/export` routes + guard, budgeted lock exemption for the system file picker ([docs/CRYPTO.md §17](docs/CRYPTO.md)). **Server schema unchanged.** · **host 713/713** |
| Flutter — Phase 5 Patch 2 (Google Authenticator import) | ✅ (2026-09-02) `otpauth-migration://` transfer-QR import: hand-written protobuf wire decoder (**no codegen** — proto3 field presence is what keeps a counter-less HOTP entry from being imported with a guessed 0), multi-QR batch collector (any scan order; a code from another export is never merged; partial import allowed), migration mode inside the existing `ScanPage` (no new route, no guard/DI change) + `SecureScreenScope` on the scan screen, shared `ImportPreviewView`, paste guard in the add-by-URI sheet. MD5 and unlabelled-type entries are skipped, not guessed; **Steam is deliberately not promoted** (Google cannot hold a Steam token). **Server schema unchanged, docs/CRYPTO.md unchanged.** · **host 899/899** |
| Admin panel (Next.js) | ⏳ Phase 6 |

**Live backend project:** `authenticator-dev` (Supabase, eu-central-1, PG17). Details: [PROJECT_INFO.md](supabase/PROJECT_INFO.md).

### Import source support

| Source | Support | Note |
|---|---|---|
| Aegis — plain JSON export | ✅ | `db`/`header` schema, auto-detected |
| 2FAS — schema v4 export | ✅ | `services` |
| Google Authenticator — transfer QR | ✅ | `otpauth-migration://`, single- and multi-QR exports |
| project_auth — own encrypted backup | ✅ | `projectauth-backup` v1, opens with the backup password |
| Aegis / 2FAS — **encrypted** export | ❌ | Recognized and named (`EncryptedSourceException`), not decrypted: export the plain file from the source app |

The QR import needs the live camera; a pasted migration link or a saved QR image file is Patch 3.

---

## Phases (summary)

0. **Foundation setup** — Flutter skeleton, dependencies, go_router, DI
1. **OTP engine** — TOTP/HOTP/Steam (RFC 6238/4226), QR scanning, vault UI (works serverless)
2. **E2E crypto** — libsodium, master key + recovery key, local vault encryption
3. **Supabase auth + sync** — DB ✅; Flutter Patch 1 (auth) ✅ + Patch 2 (key_attributes) ✅ + Patch 3 (token sync + changePassword UPDATE) ✅ + Patch 4 (devices + catalog/feature_flags/announcements + token_sync kill-switch) ✅ — **Phase 3 DONE**
   - **Phase 3.5 — CI, deps, hardening (2026-09-01) — DONE:** GitHub Actions (`analyze --fatal-infos` + `test`), unused-dependency cleanup, ref-counted screen-capture protection, Supabase config fail-fast
4. **Social sign-in + push** — Google/Apple Sign-In, FCM *(developer accounts required)*
5. **Import/Export + catalog** — Patch 1 (Aegis + 2FAS import, encrypted backup export) ✅ 2026-09-02 + Patch 2 (Google Authenticator transfer QR) ✅ 2026-09-02; tags/folders and migration import from a pasted link / QR image file → Patch 3
6. **Admin panel** — Next.js, analytics, announcements/push, feature flags
7. **Hardening & release** — security review, store

Detailed task list: [PLAN.md](PLAN.md).

---

## Development

### Backend (Supabase)
Migrations live under `supabase/migrations/` (3 files, ordered by timestamp — see
[supabase/migrations/README.md](supabase/migrations/README.md)).

> ⚠️ **These migrations have ALREADY been applied to the existing live project (`authenticator-dev`).**
> Do not run `db push` again — you will get a "relation already exists" error.

To apply to a **new/clean project**:
```bash
supabase link --project-ref <NEW_REF>
supabase db push          # applies the three migrations in order
# or run the migration files one by one in the Supabase SQL editor / via MCP
```
To run the security tests: [supabase/tests/security_rls_tests.sql](supabase/tests/security_rls_tests.sql).

For **manual deployment steps** (outside the migration scope), see [PROJECT_INFO.md](supabase/PROJECT_INFO.md) → Deployment Checklist.

### Flutter
The project root is the Flutter app (`lib/`, `pubspec.yaml`). Required: Flutter 3.38+ (the toolchain is pinned via `.fvmrc`).

**First-time setup — Supabase credentials.** Since 2026-09-01 the app embeds **no** URL/key fallback:
`SupabaseConfig.ensureConfigured()` runs before `Supabase.initialize` and throws a `StateError` in debug **and**
release if the defines are missing or malformed. Copy the template and fill in the real values
(from [PROJECT_INFO.md](supabase/PROJECT_INFO.md)); `env/*.json` is gitignored, only `env/dev.example.json` is tracked:

```bash
cp env/dev.example.json env/dev.json   # then edit SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY
```

In Android Studio / IntelliJ the same flag goes into Run → Edit Configurations → **Additional run args**
(`--dart-define-from-file=env/dev.json`); `.idea/` is gitignored, so this is a per-developer setting.

```bash
flutter pub get
flutter analyze          # lint — currently clean (CI runs it with --fatal-infos)
flutter test             # 713/713 host — no --dart-define needed (Supabase is not initialized in tests)
flutter run --dart-define-from-file=env/dev.json   # run on a device/emulator
```

> **libsodium tests on device/simulator:** the `sodium_libs` platform plugin is not loaded
> on the plain `flutter test` VM host → crypto round-trip tests live under
> `integration_test/` (**50 tests**: sodium service 8 + KeyManager 12 +
> encrypted vault/migration 18 + backup service 12). Run: `flutter test integration_test/ -d <device>`.
>
> **CI:** `.github/workflows/ci.yml` runs `flutter analyze --fatal-infos` + `flutter test` on every push to `main` and
> every pull request (Flutter 3.38.6, ubuntu-latest); the integration suite is excluded because it needs a device/simulator.

**Folder structure** (feature-first + layered):
```
lib/
  core/
    otp/        TOTP/HOTP/Steam/Base32 engine + otpauth:// parse (pure Dart, tested)
    di/         hand-written get_it composition root (configureDependencies) — no codegen
    router/     go_router routes (Routes constants)
    theme/      Material 3 light/dark theme
  features/
    vault/      data/ — VaultRepository (secure_storage persistence)
                presentation/{bloc,pages,widgets} — VaultCubit, VaultPage (search), OtpCard
    scan/       presentation — ScanPage (mobile_scanner QR scanning; migration mode),
                MigrationScanController (camera-free migration brain)
    import_export/  domain/ — ImportService, BackupService, DocumentPort, GoogleMigrationCollector (pure Dart)
                data/ — AegisParser, TwoFasParser, ProtobufReader, GoogleAuthParser, FilePickerDocumentPort
                presentation/pages — ImportPage, ExportPage; widgets/ — ImportPreviewView
  main.dart     DI init + MaterialApp.router + VaultCubit provider
test/
  core/otp/     RFC 4226/6238 test vectors + URI parse tests
```

> **OTP core details:** [docs/OTP_ENGINE.md](docs/OTP_ENGINE.md).
>
> 🔐 **Crypto package decision (implemented in Phase 2):** `sodium: ^3.4.6` + `sodium_libs: ^3.4.6+4`. `sodium 4.x` requires Dart SDK `^3.11.0`; the project is on Dart `3.10.7` (Flutter 3.38.6 stable) → **4.x cannot be resolved**, so 3.x is a deliberate and correct decision. `sodium_libs` is tagged "discontinued" on pub but it installs pre-built libsodium binaries and does NOT REQUIRE the native-assets/experiment flag; the 3.x line works. Later, once Flutter moves to Dart 3.11+, migrating to 4.x native assets will be a separate small migration. The XChaCha20-Poly1305 IETF + Argon2id algorithm decision does not change. Details: [docs/CRYPTO.md](docs/CRYPTO.md).

---

## Important security notes (for developers)

- **Login password ≠ master password.** The Supabase session is for identity; the master password is for the E2E key. They are kept separate.
- **The secret key (`sb_secret_...`) is never embedded in the client** — backend only (Next.js / Edge Function).
- **libsodium:** use `crypto_aead_xchacha20poly1305_ietf_*` for XChaCha20-Poly1305; do **not** use `crypto_secretbox` (XSalsa20).
- All DB access is subject to RLS; cross-user isolation has been tested.
- **Supabase URL/key come only from `--dart-define`** — there is no embedded fallback; `SupabaseConfig.ensureConfigured()` fails fast in debug and release. Never commit `env/dev.json`.
- **Screen-capture protection:** wrap a sensitive page's outermost widget in `SecureScreenScope` — never call enable/disable by hand (the counter is ref-counted in Dart because the native flag is last-caller-wins). ⚠️ On iOS this only hides the background snapshot; screenshots/recording are **not** blocked. See [docs/CRYPTO.md §15](docs/CRYPTO.md).
- **Master password policy:** min 12 characters + at least 3 character classes (`KeyManager.meetsPolicy` is the single source of truth).
