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
| [admin/README.md](admin/README.md) | Admin panel (Phase 6): setup, the three access paths, module contract, routes, security invariants, smoke checklist |
| [CHANGELOG.md](CHANGELOG.md) | Version/progress log |

---

## Current status (2026-09-02)

| Stage | Status |
|---|---|
| Architecture & plan | ✅ Matured (multi-round review + verification) |
| Supabase backend (Phase 3 DB) | ✅ Implemented + clean security scan (0 warnings) + end-to-end tests (8/8) + least-privilege hardening (0003) |
| Custom Access Token Hook | ✅ Enabled + admin claim verified |
| Flutter — Phase 0 skeleton | ✅ Project + feature-first structure + DI/router/theme + dependencies |
| Flutter — Phase 1 OTP core | ✅ TOTP/HOTP/Steam/Base32 + `otpauth://` (validated, stable token id) + vault UI + QR scanning (mobile_scanner) + secure_storage persistence + search · `analyze` clean |
| Flutter — Phase 2 E2E crypto (Patches 1–3) | ✅ `CryptoService`/SodiumSumo (XChaCha20-Poly1305 IETF + Argon2id), `KeyManager` (setup/unlock/recovery/changePassword), in-house BIP39 (MIT, official vectors), `EncryptedVaultRepository` (token-based, unchanged-blob + corrupt-record protection, integrity), Phase 1→2 migration (commit-marker, upsert) · **host 122/122 + integration 34/34** (sim; the integration suite is **50** today) |
| Flutter — Phase 2 UI/session (Patch 4) | ✅ Setup/Unlock/Recovery UI + route guard (based on lock state) + lifecycle lock (paused/inactive) + corruption banner/integrity screen + `KeyAttributesStore`/`resetVault` + DI/main rewiring + **full UI/UX redesign** (embedded Geist/GeistMono, simple-icons CC0, CountdownRing, IssuerAvatar, card/list toggle, tap-to-copy, a11y) · **host 186/186** · per the design system (kept local) |
| Flutter — Phase 2 biometrics (Patch 5) | ✅ Biometric unlock shortcut: 3rd wrap (`biometricEncryptedMasterKey`) + OS-keystore access control (iOS Secure Enclave + `biometryCurrentSet`, Android `strongBiometricOnly`+`enforceBiometrics`), the real gate = `storage.read` (no double prompt; `local_auth` for availability only), Settings enable/disable + UnlockPage button, `device_info_plus` API<28 gate, lifecycle inactive-vs-paused distinction, password+recovery always work · **host 220/220** · see [docs/CRYPTO.md §11](docs/CRYPTO.md) |
| Flutter — Phase 3 auth (Patch 1) | ✅ Supabase email/password identity (registration/login/logout + email confirmation, PKCE deep-link). Two-gate guard (identity OUTERMOST → vault lock), `unknown→/splash` (no masterKey crash), `onAuthStateChange` `onError` (crash prevention), signOut → vault lock + network-error-resilient `signedOut`, multi-vault per uid (namespace + account-linking + legacy `bmk` cleanup). Login password ≠ master password. **NO sync yet (Patches 2–3).** · **host 257/257** |
| Flutter — Phase 3 sync (Patch 2) | ✅ `key_attributes` upload/restore (already-encrypted KDF + KEK/recovery-wrapped master key). On a new device, Supabase login → pull from cloud → master password → unlock. `ByteaCodec` (single point for bytea↔Uint8List), guarded `unlocked` insert on upload (server-wins), `restoring`/`restoreFailed` state: while fetching shows `/splash` (does not fall back to setup), network error gets a separate screen. **masterKey/KEK/secret/bmk NEVER go to the server.** Server schema unchanged. **NO token sync yet (Patch 3).** · **host 293/293** |
| Flutter — Phase 3 token sync (Patch 3) | ✅ Encrypted token push/pull + soft-delete (tombstone) + arrival-order LWW (server `updated_at`; per-record `sv` cursor). `RawTokenStore` (raw port without decrypt) + `SupabaseTokenRepository` + `TokenSyncService`. Realtime = trigger only → REST pull (bytea #1180); corrupt-row quarantine (`safeCursorIso` cap). **changePassword now performs an UPDATE on `key_attributes`** (`attrs_dirty_v1` retry marker); masterKey does not change → no token re-encryption. Settings live-sync toggle + AppBar sync indicator. **Only opaque ciphertext/nonce goes to the server; the `uid==null` legacy path is inert.** · **host 347/347** |
| Flutter — Phase 3 devices+catalog (Patch 4) | ✅ `devices` record (random `device_id` uuid v4, GLOBAL; signedIn→register, resume→`last_seen` heartbeat + 0-row register-fallback; owner-only RLS). Public read tables (read-only): `catalog_services` → add-token issuer canonicalization (`logo_url` is IGNORED — offline/privacy), `feature_flags` → **`token_sync_enabled` kill-switch** (gate inside `TokenSyncService` → Realtime bypass disabled; `ensureLoaded` cache-ready; fallback=true; token sync ONLY — key_attributes excluded), `announcements` → read-only Settings section (`audience` client-filtered). NO Realtime → fetch+cache. **Cross-account correlation tradeoff documented.** Server schema unchanged; E2E untouched. · **host 413/413** |
| Flutter — Phase 3.5 hardening | ✅ Security review fixes (release manifest + Auto Backup off, master password **min 12 + ≥3 character classes**, conditional clipboard auto-clear, `resetVault` server tombstone cleanup + `ResetPendingStore` retry, strict `OtpAccount.fromJson`), **ref-counted `SecureScreen`/`SecureScreenScope`** on vault/unlock/setup/recovery, Supabase config **fail-fast** (embedded fallbacks removed, `--dart-define` only), 8 unused codegen/test packages dropped + minor upgrades, **GitHub Actions CI** · **host 454/454** |
| Flutter — Phase 5 Patch 1 (import/export) | ✅ (2026-09-02) Aegis (plain JSON) + 2FAS (schema v4) import: format auto-detection, tolerant per-entry skipping, Base32-canonicalizing dedupe key, preview → confirm → single `VaultCubit.addAll`. **Encrypted backup export** (`projectauth-backup` v1: Argon2id + XChaCha20-Poly1305 through the existing `CryptoService`, KDF parameters bound into the AAD, backup password independent of the master password). `file_picker` `DocumentPort` (now ^12.0.0), `/import` `/export` routes + guard, budgeted lock exemption for the system file picker ([docs/CRYPTO.md §17](docs/CRYPTO.md)). **Server schema unchanged.** · **host 713/713** |
| Flutter — Phase 5 Patch 2 (Google Authenticator import) | ✅ (2026-09-02) `otpauth-migration://` transfer-QR import: hand-written protobuf wire decoder (**no codegen** — proto3 field presence is what keeps a counter-less HOTP entry from being imported with a guessed 0), multi-QR batch collector (any scan order; a code from another export is never merged; partial import allowed), migration mode inside the existing `ScanPage` (no new route, no guard/DI change) + `SecureScreenScope` on the scan screen, shared `ImportPreviewView`, paste guard in the add-by-URI sheet. MD5 and unlabelled-type entries are skipped, not guessed; **Steam is deliberately not promoted** (Google cannot hold a Steam token). **Server schema unchanged.** · **host 909/909** |
| Flutter — Phase 5 audit follow-ups | ✅ (2026-09-02) Post-merge audit of Patches 1–2, 23 findings closed: live-record-beats-tombstone (an id-preserving restore used to write a live record AND its tombstone → silent loss on the next merge + a permanently wedged push), catalog-driven dedupe canonicalization shared by `VaultCubit` and `ImportService`, 1024-entry import ceiling, push/merge mutex in `TokenSyncService`, kill-switch catch-up resync, one-record-per-id
on the push path and a dirty-local-wins rule on the first pull (no cursor = nothing proves the server row is
newer); **Steam issuer heuristic removed from Aegis/2FAS** (the declared type is the only authority), official 2FAS `reference` encryption predicate, SHA224/SHA384/MD5 → `unsupportedType`, 512-byte string caps, fixtures aligned with real exports; **iOS export leftover in Documents shredded** (file_picker wrote the backup there and never removed it → it rode into the iCloud backup), camera action guards, bounded skip list, `SecureScreen` retry-on-failure, 10-minute absolute cap on the file-picker lock exemption; docs/CRYPTO.md §15/§16/§17 resynced with the code. **Server schema unchanged.** · **host 992/992** |
| Flutter — deps: file_picker 12 + device_info_plus 13 | ✅ (2026-09-02) One coupled major upgrade (`file_picker` 11.0.3 → 12.1.3, `device_info_plus` 12.4.0 → 13.2.0 — neither resolved alone, `win32 ^6` vs `^5`). **iOS drops the `DKImagePickerController`/`DKPhotoGallery`/`SDWebImage`/`SwiftyGif` pod chain** (12.x moves Apple platforms into the federated `file_picker_darwin`), which closes the `NSPhotoLibraryUsageDescription` release-review item; **minimum iOS deployment target 13.0 → 14.0** (same device set — iPhone 6s and later). `DocumentPort` migrated to `pickFile()` + `PlatformFile.readAsBytes()` + `saveFile() → Uri?`; behaviour unchanged, and the size ceiling now rejects an oversized file before it is read into memory. The iOS `saveFile` leftover moved upstream to `NSTemporaryDirectory()` (out of the iCloud backup) — the shredder is kept as defence in depth. **Server schema unchanged.** · **host 996/996** |
| Flutter — Phase 5 Patch 3 (tags, pasted links, QR from image) — **Phase 5 DONE** | ✅ (2026-09-02) **Tags:** `OtpAccount.tags` (≤8 labels, ≤32 runes) inside the encrypted blob — **no record-version bump, no AAD change, no backup-envelope change**, and the key is omitted when empty so an untagged vault serializes byte-identically to before (no re-encrypt/re-push wave on upgrade). Aegis `db.groups` + the legacy singular `group`, and 2FAS `groups`/`groupId`, are mapped onto tags on import; tags are deliberately NOT part of `dedupeKey`. Vault-wide rename/delete with one persist + one push each, session-scoped single-selection filter strip, metadata-only edit sheet (the cubit does not even accept a secret). **Behaviour change:** a long press no longer deletes outright — it opens an action sheet, and every delete path is confirmed. **Pasted migration link** in the add sheet (the clipboard is never read programmatically) and **"Görüntüden oku"** in `ScanPage` (`analyzeImage`, no camera and no camera permission; the picker's plaintext copy is zero-filled and unlinked *before* the general cache sweep, and the user's original image is never touched). **Server schema unchanged.** · **host 1165/1165** |
| Admin panel — Phase 6 MVP (Next.js) | ✅ (2026-09-02) Standalone npm package under `admin/` (own lockfile, own CI workflow, **not** in the Flutter pipeline). Next.js 16.3.4 App Router + `@supabase/ssr` + shadcn/ui; auth in `src/proxy.ts` (Next 16 renamed `middleware` → `proxy`) **plus** a `requireAdmin()` re-check inside every privileged handler (JWKS-verified `app_metadata.admin === true`). Pages: `/login`, `/` (global counts + last-10 audit tail), `/users` (list/ban/unban/delete, page-local search), `/announcements`, `/catalog`, `/flags`, `/audit`, `/forbidden`. **Three access paths, never mixed:** (a) direct Postgres → `private.admin_global_stats()` as `admin_backend`, (b) secret key → `auth.admin` + all writes, (c) the admin's own session → reads under RLS. **The panel decrypts nothing**: `tokens.ciphertext`/`key_attributes` are read on no path; the only cross-user read is a count. Every privileged operation writes one `audit_logs` row, and a failed audit write is reported as such rather than as a failed operation. **Review follow-ups landed the same day (no P1):** a zero-row UPDATE/DELETE is now an error instead of a success + a false audit row (`.select('<pk>')` before revalidate/audit); `requireAdmin()` adds a fail-closed `admin_users` freshness lookup so demotion is immediate rather than waiting out the token TTL; the Postgres connection uses verified TLS (`rejectUnauthorized: true` + optional `SUPABASE_CA_CERT`) instead of `ssl: 'require'`, which does not verify; the flag payload editor warns and blocks Save rather than erasing a non-object payload; plus a `(dashboard)` error boundary, a `server-only` env split, prototype-key rejection in flag payloads, `/audit` next-page/clamp fixes and `.env.example` placeholders. **Operator steps applied 2026-09-02 (verified live against `vfyqokvgtdxxurroqbtj`):** the migration `supabase/migrations/20260902201638_admin_backend_role.sql` is **applied** (live DB version `20260902201638`; `list_migrations` matches the repo's four files one-to-one), the roles exist — `admin_backend` (NOLOGIN, NOINHERIT; `usage` on `private` + `execute` on `private.admin_global_stats()`, no table privileges) and `admin_app` (LOGIN, member of `admin_backend`, no `bypassrls`/`superuser`/`createrole`), with `has_table_privilege(…, 'public.tokens'/'public.key_attributes', 'select')` = **false** for both — and the Supabase Root 2021 CA is now bundled at `admin/certs/supabase-prod-ca-2021.crt` for `SUPABASE_CA_CERT`. The **`admin_app` password was set by the operator on 2026-09-02** (Dashboard SQL editor — deliberately never done by an agent) and **access path (a) was smoke-tested live**: connected as `admin_app` to `aws-1-eu-central-1.pooler.supabase.com` on both 6543 and 5432 with verified TLS, `set local role admin_backend` + `select private.admin_global_stats()` returned the counts, and `select count(*) from public.tokens` was refused with `42501`. **Still operator-only:** the `sb_secret_…` key must be pasted into `admin/.env.local` (without it you can sign in but no signed-in page renders — `requireAdmin()`'s freshness lookup needs it) and `public.admin_users` still has no real row. One canonical list: [PROJECT_INFO.md → Bekleyen operatör adımları](supabase/PROJECT_INFO.md#bekleyen-operatör-adımları-operator-todo). **Follow-ups (see CHANGELOG "Follow-ups (2026-09-02)"):** `/announcements`, `/catalog` and `/flags` are now paged like `/audit` (50 rows/page via `?page=`, `count: 'exact'` + `.range()`, a deterministic tiebreaker in every ordering, shared `lib/paging.ts`), and `admin-ci.yml` runs `npm audit --omit=dev --audit-level=high` after `npm ci` (production dependencies only; 0 vulnerabilities today). **No Dart/crypto/schema change.** · **admin 256/256**, Flutter host 1188/1188 unchanged |
| Flutter — Phase 7 key-lifecycle review | ✅ (2026-09-02) Read-only review of key lifecycle + memory wiping, **2 P1 + 6 P2 + 6 P3 all fixed**. **P1s:** a non-interactive sign-out (gotrue refresh failure / server-side revocation / expiry / global sign-out from another device) never closed the E2E gate — the master key stayed resident and re-login as the same uid re-entered the **unlocked** vault on the account password alone; and `flutter_secure_storage`'s Android `resetOnError: true` default silently deleted `vault_key_attributes_v1` on a decrypt failure (Android device-to-device transfer is a concrete trigger), turning an existing vault into a fresh **setup** screen. Now: explicit storage options (`resetOnError: false`, `migrateWithBackup: true`, iOS `unlocked_this_device`) + `dataExtractionRules` excluding the plugin prefs from cloud backup **and** device transfer + `PlatformException` → `keyAttributesCorrupted` with retry; plaintext holders wiped **synchronously inside `_disposeKey()`** before the key is freed (unrooting, not erasing); biometric prompt flag in a `finally`; `VaultLockState.stringify => false` (the recovery mnemonic was printable in assert-enabled builds); Supabase session + PKCE verifier moved to Keychain/Keystore with a one-time prefs migration; `SensitiveClipboard` (iOS `localOnly` + `expirationDate`, Android `EXTRA_IS_SENSITIVE`); zero-fill in the token repo; `resetVault` through `lock(immediate: true)`; OTP seed decoded once per card; AAD built with `utf8.encode` (byte-identical, pinned by a test). **No schema, AAD or backup-format change.** A same-day adversarial re-review confirmed all fourteen closed and raised six new P3s, also fixed: `forgetPlaintext` narrowed to the decrypted cache (it was dropping pending tombstones and preserved corrupted records that `save()` re-writes), the unlock/recover/biometric paths now route a storage `PlatformException` to the integrity screen the way `bootstrap()` did, a repeated "Yeniden dene" is observable (`attempt` counter + spinner), the plaintext-wipe wiring is pinned by a router test that asserts the accounts are gone **without pumping a frame**, the session migration aborts instead of letting a stale prefs session overwrite a live one, and the transient `/unlock` flash during a reset is documented rather than papered over. Open by design: idle auto-lock and in-app change-master-password (PLAN Phase 7). · **host 1268/1268** · see [docs/CRYPTO.md §18](docs/CRYPTO.md) |

**Live backend project:** `authenticator-dev` (Supabase, eu-central-1, PG17). Details: [PROJECT_INFO.md](supabase/PROJECT_INFO.md).

### Import source support

| Source | Support | Note |
|---|---|---|
| Aegis — plain JSON export | ✅ | `db`/`header` schema, auto-detected |
| 2FAS — schema v4 export | ✅ | `services` |
| Google Authenticator — transfer QR | ✅ | `otpauth-migration://`, single- and multi-QR exports |
| project_auth — own encrypted backup | ✅ | `projectauth-backup` v1, opens with the backup password |
| Aegis / 2FAS — **encrypted** export | ❌ | Recognized and named (`EncryptedSourceException`), not decrypted: export the plain file from the source app |

**Groups → tags** (Patch 3):

| Source | Groups imported as tags | Note |
|---|---|---|
| Aegis | ✅ | `db.groups` (`{uuid, name}`) referenced by `entry.groups`, plus the legacy singular `entry.group` (a name, not a uuid). Multiple groups per entry are kept |
| 2FAS | ✅ | root `groups` (`{id, name}`) referenced by `service.groupId` → at most one tag per service |
| Google Authenticator | — | the transfer payload carries no grouping field at all |
| project_auth backup | ✅ | tags ride inside the payload; a restore is tag-lossless |

An unresolvable group reference contributes no tag, silently — it never drops the entry and never shows up as a
skipped record.

Three ways in for a Google transfer QR: the live camera, a **pasted `otpauth-migration://` link**, or a **saved QR
image file** (Patch 3). Reading from an image is not available on the iOS Simulator or the web.

---

## Phases (summary)

0. **Foundation setup** — Flutter skeleton, dependencies, go_router, DI
1. **OTP engine** — TOTP/HOTP/Steam (RFC 6238/4226), QR scanning, vault UI (works serverless)
2. **E2E crypto** — libsodium, master key + recovery key, local vault encryption
3. **Supabase auth + sync** — DB ✅; Flutter Patch 1 (auth) ✅ + Patch 2 (key_attributes) ✅ + Patch 3 (token sync + changePassword UPDATE) ✅ + Patch 4 (devices + catalog/feature_flags/announcements + token_sync kill-switch) ✅ — **Phase 3 DONE**
   - **Phase 3.5 — CI, deps, hardening (2026-09-01) — DONE:** GitHub Actions (`analyze --fatal-infos` + `test`), unused-dependency cleanup, ref-counted screen-capture protection, Supabase config fail-fast
4. **Social sign-in + push** — Google/Apple Sign-In, FCM *(developer accounts required)*
5. **Import/Export + catalog** — **DONE 2026-09-02:** Patch 1 (Aegis + 2FAS import, encrypted backup export) ✅ + Patch 2 (Google Authenticator transfer QR) ✅ + Patch 3 (tags — including Aegis/2FAS groups, migration import from a pasted link and from a saved QR image) ✅; the `catalog_services` issuer matching landed back in Phase 3 Patch 4 ✅
6. **Admin panel** — **MVP DONE 2026-09-02:** Next.js 16 panel under `admin/` — global counts, user ban/unban/delete, announcements/catalog/feature-flag CRUD, audit log viewer, every privileged operation audited. FCM push triggering stays in Phase 4 (needs the Firebase project + device push tokens); the `admin_backend`/`admin_app` DB role migration was **applied** to the live project on 2026-09-02, both roles exist and the `admin_app` password was set the same day (access path (a) smoke-tested live) — what is left is operator-only (the secret key and the first `public.admin_users` row): [PROJECT_INFO.md → Bekleyen operatör adımları](supabase/PROJECT_INFO.md#bekleyen-operatör-adımları-operator-todo)
7. **Hardening & release** — security review, store

Detailed task list: [PLAN.md](PLAN.md).

---

## Development

### Backend (Supabase)
Migrations live under `supabase/migrations/` (4 files, ordered by timestamp — see
[supabase/migrations/README.md](supabase/migrations/README.md)).

> ⚠️ **All four migrations have ALREADY been applied to the existing live project
> (`authenticator-dev`).** Do not push them again — you will get a "relation already exists" error.
>
> ✅ **The fourth, `20260902201638_admin_backend_role.sql` (Phase 6 — `admin_backend` DB role), was applied on
> 2026-09-02** — the live DB version is `20260902201638` and `list_migrations` matches these four files. The
> `admin_app` login role was created by hand afterwards, granted `admin_backend`, and its **password was set
> by the operator on 2026-09-02** with `alter role admin_app password '…';` in the Dashboard SQL editor
> (never in a migration or a transcript) — connecting as that role and calling
> `private.admin_global_stats()` under `set local role admin_backend` was verified live the same day. A
> rotation is recommended (the password was transmitted in a chat). See
> [PROJECT_INFO.md](supabase/PROJECT_INFO.md) →
> [Bekleyen operatör adımları](supabase/PROJECT_INFO.md#bekleyen-operatör-adımları-operator-todo) +
> Deployment Checklist, and [admin/README.md](admin/README.md) §1.

To apply to a **new/clean project**:
```bash
supabase link --project-ref <NEW_REF>
supabase db push          # applies all four migrations in order
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
dart format --output=none --set-exit-if-changed .   # formatting gate — CI runs the same command
flutter analyze          # lint — currently clean (CI runs it with --fatal-infos)
flutter test             # 1268/1268 host — no --dart-define needed (Supabase is not initialized in tests)
flutter run --dart-define-from-file=env/dev.json   # run on a device/emulator
```

> **libsodium tests on device/simulator:** the `sodium_libs` platform plugin is not loaded
> on the plain `flutter test` VM host → crypto round-trip tests live under
> `integration_test/` (**50 tests**: sodium service 8 + KeyManager 12 +
> encrypted vault/migration 18 + backup service 12). Run: `flutter test integration_test/ -d <device>`.
>
> **CI:** `.github/workflows/ci.yml` runs `dart format --output=none --set-exit-if-changed .` +
> `flutter analyze --fatal-infos` + `flutter test` on every push to `main` and
> every pull request (Flutter 3.38.6, ubuntu-latest); the integration suite is excluded because it needs a device/simulator.
>
> **One-time local setup:** the tree was reformatted repo-wide in `7a88a0b` (whitespace only). So that this commit
> does not bury real authorship, run once per clone:
>
> ```bash
> git config blame.ignoreRevsFile .git-blame-ignore-revs
> ```

**Folder structure** (feature-first + layered):
```
lib/
  core/
    otp/        TOTP/HOTP/Steam/Base32 engine + otpauth:// parse (pure Dart, tested)
    crypto/     CryptoService (libsodium), KeyManager, in-house BIP39 (docs/CRYPTO.md)
    config/     SupabaseConfig — --dart-define only, fail-fast
    platform/   SecureScreen / SecureScreenScope (MethodChannel, ref-counted)
    ui/         design tokens + shared widgets (CountdownRing, IssuerAvatar, ...)
    di/         hand-written get_it composition root (configureDependencies) — no codegen
    router/     go_router routes (Routes constants)
    theme/      Material 3 light/dark theme
  features/
    account/    Supabase identity — AuthRepository, SessionCubit, login/register/link/splash
    auth/       vault lock — KeyManager wiring, VaultLockCubit, setup/unlock/recovery pages
    settings/   SettingsPage — biometrics, live sync, announcements, backup & transfer
    vault/      data/ — VaultRepository (secure_storage persistence)
                presentation/{bloc,pages,widgets} — VaultCubit, VaultPage (search + tag filter), OtpCard,
                  AddTokenSheet, EditTokenSheet, TokenActionSheet, TagChipsBar, TagManagerSheet
    scan/       presentation — ScanPage (mobile_scanner QR scanning; migration mode; "read from image"),
                MigrationScanController (camera-free migration brain)
    import_export/  domain/ — ImportService, BackupService, DocumentPort, GoogleMigrationCollector,
                  QrImageDecoder seam (pure Dart)
                data/ — AegisParser, TwoFasParser, ProtobufReader, GoogleAuthParser, FilePickerDocumentPort,
                  MobileScannerQrDecoder
                presentation/pages — ImportPage, ExportPage; widgets/ — ImportPreviewView, MigrationProgressBand
  main.dart     DI init + MaterialApp.router + VaultCubit provider
test/
  core/otp/     RFC 4226/6238 test vectors + URI parse tests
```

> **OTP core details:** [docs/OTP_ENGINE.md](docs/OTP_ENGINE.md).
>
> 🔐 **Crypto package decision (implemented in Phase 2):** `sodium: ^3.4.6` + `sodium_libs: ^3.4.6+4`. `sodium 4.x` requires Dart SDK `^3.11.0`; the project is on Dart `3.10.7` (Flutter 3.38.6 stable) → **4.x cannot be resolved**, so 3.x is a deliberate and correct decision. `sodium_libs` is tagged "discontinued" on pub but it installs pre-built libsodium binaries and does NOT REQUIRE the native-assets/experiment flag; the 3.x line works. Later, once Flutter moves to Dart 3.11+, migrating to 4.x native assets will be a separate small migration. The XChaCha20-Poly1305 IETF + Argon2id algorithm decision does not change. Details: [docs/CRYPTO.md](docs/CRYPTO.md).


### Admin panel (Next.js)
The panel lives in `admin/` and is a **separate npm package**: its own `package-lock.json`, its own CI workflow
(`.github/workflows/admin-ci.yml`, paths-filtered to `admin/**`, running `npm ci` → `npm audit --omit=dev
--audit-level=high` → lint → typecheck → test → build), and no involvement in `flutter analyze` /
`flutter test`. Node 22+ (`engines.node: >=22`).

```bash
cd admin
cp .env.example .env.local   # .env.local is git-ignored — fill in the four values below
npm ci
npm run dev                  # http://localhost:3000

npm run lint                 # ESLint (flat config, eslint-config-next)
npm run typecheck            # tsc --noEmit
npm run test                 # vitest — 256/256
npm run build                # next build — needs NO real secrets (env validation is request-time)
```

**Environment** (`admin/.env.local`): `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`
(public by definition, though today read only on the server — the panel has no browser Supabase client), plus
the **server-only** `SUPABASE_SECRET_KEY` (`sb_secret_…`), `DATABASE_URL` (the `admin_app` login role) and
`SUPABASE_CA_CERT` (the Postgres CA, PEM). The schema rejects legacy `eyJ…` JWT anon/service_role keys
outright. Full table, the operator SQL for the DB role, the three access paths and the module contract:
[admin/README.md](admin/README.md).

> ⏳ **Before the dashboard shows numbers — state on 2026-09-02:** the migration is **applied** and both roles
> (`admin_backend`, `admin_app`) exist; the Postgres CA is **bundled in the repo** at
> `admin/certs/supabase-prod-ca-2021.crt` (the Supabase Root 2021 CA is a public root certificate, not a
> secret) — load it into `SUPABASE_CA_CERT` with the one-liner in `admin/certs/README.txt`. The connection
> verifies the server certificate, and the Supavisor pooler chain is rooted at that CA: an
> `openssl s_client -starttls postgres` handshake against it returned `Verify return code: 0 (ok)` on
> 2026-09-02.
>
> The **`admin_app` password was set on 2026-09-02** and that role is in `DATABASE_URL`; connecting through
> the pooler on 6543 and 5432, `set local role admin_backend` + `select private.admin_global_stats()` returned
> counts while `select count(*) from public.tokens` was refused with `42501` — access path (a) works
> end to end. Rotating that password is recommended (it was transmitted in a chat).
>
> **What remains is operator-only:** paste the `sb_secret_…` key into `admin/.env.local`, and insert at least
> one row into `public.admin_users` (none yet — `auth.users` currently holds only a UI-test account), or
> nobody gets past `/login`. Without the secret key you can submit `/login` successfully but no signed-in page
> renders: `requireAdmin()`'s `admin_users` freshness lookup uses the secret-key client, so the redirect to
> `/` fails in the `(dashboard)` layout's env validation and lands on that route group's error boundary.
>
> 📋 **The one canonical pending list** (where, how, what each unblocks):
> [PROJECT_INFO.md → Bekleyen operatör adımları](supabase/PROJECT_INFO.md#bekleyen-operatör-adımları-operator-todo).

---

## Important security notes (for developers)

- **Login password ≠ master password.** The Supabase session is for identity; the master password is for the E2E key. They are kept separate.
- **The secret key (`sb_secret_...`) is never embedded in the client** — backend only (Next.js / Edge Function).
- **libsodium:** use `crypto_aead_xchacha20poly1305_ietf_*` for XChaCha20-Poly1305; do **not** use `crypto_secretbox` (XSalsa20).
- All DB access is subject to RLS; cross-user isolation has been tested.
- **Supabase URL/key come only from `--dart-define`** — there is no embedded fallback; `SupabaseConfig.ensureConfigured()` fails fast in debug and release. Never commit `env/dev.json`.
- **Screen-capture protection:** wrap a sensitive page's outermost widget in `SecureScreenScope` — never call enable/disable by hand (the counter is ref-counted in Dart because the native flag is last-caller-wins). ⚠️ On iOS this only hides the background snapshot; screenshots/recording are **not** blocked. See [docs/CRYPTO.md §15](docs/CRYPTO.md).
- **Master password policy:** min 12 characters + at least 3 character classes (`KeyManager.meetsPolicy` is the single source of truth).
- **Locking drops the plaintext, not only the key.** Anything that holds decrypted secrets in memory must register a synchronous cleaner with `VaultLockCubit.registerPlaintextHolder()` (and unregister on dispose) — the holders run inside `_disposeKey()` *before* the master key is freed, because in the background there is no frame to rely on. A test fake of `VaultLockCubit` must therefore implement `registerPlaintextHolder` (`noSuchMethod`'s `null` cannot satisfy its `VoidCallback` return). This makes secrets **unreachable, not erased** — see [docs/CRYPTO.md §3 and §18](docs/CRYPTO.md).
- **The shared `FlutterSecureStorage` options are load-bearing** (`secureStorageOptions()`): `resetOnError: false` — the plugin default `true` silently deletes the key attributes on a read error, which reads as "uninitialized" and leads to an overwriting setup — plus `migrateWithBackup: true` and iOS `unlocked_this_device`. They are asserted by a test; do not drop them, and re-verify `android/app/src/main/res/xml/data_extraction_rules.xml` against the plugin's own prefs file names on every `flutter_secure_storage` upgrade. See [docs/CRYPTO.md §9.1](docs/CRYPTO.md).
- **Copy sensitive text with `SensitiveClipboard`, never `Clipboard.setData`** — plain `setData` joins iOS Universal Clipboard (off-device) and shows up in the Android 13+ clipboard preview. Keep the caller's conditional clear timer: Android has no OS-level clipboard expiry. See [docs/CRYPTO.md §16.5](docs/CRYPTO.md).
