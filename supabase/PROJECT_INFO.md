# Supabase Project Info — authenticator-dev

> Development project. Migrations applied + security scan CLEAN (2026-06-06).

| Field | Value |
|---|---|
| Project name | `authenticator-dev` |
| Project ref | `vfyqokvgtdxxurroqbtj` |
| API URL | `https://vfyqokvgtdxxurroqbtj.supabase.co` |
| Region | `eu-central-1` |
| Postgres | 17.6 |
| Publishable key (client) | `sb_publishable_rxrL2mVbh1XgojMexy1cMw_Og8wE3xI` |

## How to run the Flutter app (credentials are NOT in the source)

`lib/core/config/supabase_config.dart` reads both values from `--dart-define`
and has **no embedded fallback**. A missing/malformed value throws a
`StateError` before `Supabase.initialize` — in debug builds too, so a
misconfigured run can never silently reach an unintended project.

1. Copy the template and fill it in with the values from the table above:
   ```bash
   cp env/dev.example.json env/dev.json     # env/*.json is git-ignored
   ```
2. Run / build:
   ```bash
   flutter run   --dart-define-from-file=env/dev.json
   flutter build apk --dart-define-from-file=env/dev.json
   # or, without a file:
   flutter run --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co \
               --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
   ```
3. **Android Studio / IntelliJ:** `.idea/` is git-ignored, so run configurations
   cannot be committed — each developer sets this up once:
   Run → Edit Configurations… → (the `main.dart` configuration) →
   **Additional run args:** `--dart-define-from-file=env/dev.json`
   (VS Code equivalent: `"toolArgs": ["--dart-define-from-file=env/dev.json"]`
   in `.vscode/launch.json`.)

`flutter test` needs no configuration (the host tests use fakes and never touch
Supabase).

## Client usage (Flutter)
```dart
await Supabase.initialize(
  url: SupabaseConfig.url,             // --dart-define=SUPABASE_URL=...
  // The 'publishableKey' parameter (NOT the old 'anonKey').
  publishableKey: SupabaseConfig.publishableKey,
);
```
> Notes:
> - **API verified** — in the source of the installed `supabase_flutter 2.14.1` (`lib/src/supabase.dart`),
>   `initialize({required String url, String? publishableKey, @Deprecated(...) String? anonKey, ...})`.
>   So `publishableKey:` is a REAL parameter (it does not fail at compile time), and `anonKey` is now
>   **`@Deprecated`** ("will be removed in a future major version"). Some online quickstart/pub.dev
>   doc pages still pass the publishable key to `anonKey` — those lag behind the current package;
>   the final authority is the signature of the installed package. `publishableKey:` is both correct and future-proof.
> - The secret key (`sb_secret_...`) is NOT written here — it belongs only to the backend (Next.js admin / Edge Function). Obtain it from Dashboard > Settings > API Keys and keep it in env.
> - Do not hardcode the key into the code; pass it via `--dart-define` / env (good practice even though the publishable key is low-privilege).

## Applied migrations (aligned one-to-one with live — see migrations/README.md)
- `20260606152227_init_authenticator` — tables + RLS + hook + grant + trigger + publication + private aggregate
- `20260606152553_rls_initplan_optimization` — `auth.uid()` → `(select auth.uid())` (init-plan optimization; the audit FK index `idx_audit_logs_actor` was moved into the init migration, so it was removed from this file)
- `20260606162359_least_privilege_revoke` — revoke redundant `anon`/`authenticated` table privileges (defense in depth)

## Security scan (get_advisors) — latest: 2026-06-06 (after 0003)
- **security: 0 warnings** ✅
- performance: only 1× `unused_index` (`idx_audit_logs_created`, INFO — empty DB; index kept by design)

## Privilege model (after 0003 — defense in depth)
The `anon`/`authenticated` roles hold only the table privileges they need:
| Table | anon | authenticated |
|---|---|---|
| announcements / catalog_services / feature_flags | SELECT | SELECT |
| tokens / key_attributes | — | SELECT, INSERT, UPDATE |
| devices | — | SELECT, INSERT, UPDATE, DELETE |
| audit_logs | — | SELECT (RLS `is_admin()`) |
| admin_users | — | — |
Write/privileged operations are reserved for `service_role` only (backend secret key, RLS bypass). RLS + table grant = two layers.

## Tables (all with RLS enabled)
admin_users · key_attributes · tokens · devices · announcements · catalog_services · feature_flags · audit_logs
+ `private.admin_global_stats()` (security definer, not exposed to the Data API)

## DEPLOYMENT CHECKLIST (manual steps — NOT part of the migrations)
- [x] Custom Access Token Hook enabled: Dashboard > Auth Hooks > "Customize Access Token (JWT) Claims" → Postgres → `public.custom_access_token_hook` ✅
- [x] Hook verified: admin→`{admin:true}`, normal→`{admin:false}` (see tests/TEST_REPORT.md) ✅
- [ ] Do NOT add the `private` schema to "Exposed schemas" (default; must not be added — just verify)
- [ ] Backend DB role + `private` USAGE + function EXECUTE grant (ARCHITECTURE §6, migration Pattern A/B) — before Phase 6
- [ ] First **real** admin: `insert into public.admin_users (user_id) values ('<auth-user-uuid>');` (secure channel) — once a real user exists
- [ ] **Phase 3 Patch 1 — Email confirmation:** Dashboard > Auth > Providers > Email → "Confirm email" ON (confirmation email after signup).
- [ ] **Phase 3 Patch 1 — Redirect URL:** Dashboard > Auth > URL Configuration > Redirect URLs → add `dev.mustafakara.projectauth://login-callback` (PKCE deep-link callback; matches the native intent-filter/URL scheme).
- [ ] **Phase 3 Patch 2 — bytea format confirmation (manual, schema unchanged):** `key_attributes` upload/restore must be tested on-device against real Supabase — does the `insert` via `ByteaCodec` (`\x`+hex) match PostgREST's bytea acceptance, is the `select` round-trip lossless, is RLS owner-only? If the format differs, it is fixed in a single place at `lib/features/account/data/bytea_codec.dart` (NO DB migration REQUIRED).
- [ ] **Phase 3 Patch 3 — token sync device test (manual, schema unchanged):** against real Supabase:
  (1) `tokens` bytea `upsert(onConflict:id)`/`select(gt updated_at)` round-trip lossless + RLS owner-only;
  (2) does the Realtime `tokens` publication trigger arrive → REST pull (the bytea payload is NOT READ — #1180);
  (3) new device: login → key_attributes restore → unlock → token full-pull → list populated;
  (4) soft-delete cross-device (`deleted=true` UPDATE → the other device hides it; NO hard DELETE);
  (5) arrival-order LWW (two devices, same token → the last to arrive wins; no echo loop);
  (6) after changePassword, a fresh-restore pulls the NEW password wrapper (`key_attributes` was UPDATEd);
  (7) corrupt-row quarantine (manual corrupt row → skipped, the vault does not fall over, the cursor does not skip the gap).
  If the bytea format differs, it is fixed in a single place at `bytea_codec.dart` (NO DB migration REQUIRED).
- [ ] **Phase 3 Patch 3 — Realtime publication check:** `tokens` is already in the `supabase_realtime` publication (init migration §7b). In a new/clean project, `alter publication supabase_realtime add table public.tokens;` must have been applied.
- [ ] **Phase 3 Patch 4 — devices + public read tables device test (manual, schema unchanged):** against real Supabase:
  (1) `devices` owner-only RLS: signedIn → register (composite PK `user_id,device_id` upsert, no duplicates); `list` only your own devices; resume → `last_seen` updated; **register-fallback** (delete the row on the server → resume → 0 rows → recreates the register row);
  (2) `catalog_services`/`feature_flags`/`announcements` public SELECT (anon+authenticated read; client INSERT/UPDATE rejected — no write grant);
  (3) **`token_sync_enabled` kill-switch:** add `('token_sync_enabled', false)` to `feature_flags` → token push/pull STOPS (no sync even if a Realtime event arrives; toggle hidden); the catch-up pull also does not start on an empty-cache first launch; delete the flag/set true → sync resumes; **`key_attributes` restore/backfill is NOT AFFECTED by this flag** (identity recovery still works);
  (4) issuer canonicalization: add `(name:'GitHub', issuer:'github')` to `catalog_services` → add a token with the `github` issuer → it is stored as `GitHub` (the network logo is NOT DOWNLOADED);
  (5) announcement: add `audience='all'` to `announcements` → visible in Settings; `audience='web'` → hidden (platform filter).
- [ ] **Phase 3 Patch 4 — seed data (optional, for demo):** `catalog_services`/`feature_flags`/`announcements` start empty (the tables exist, no rows). For demo/test, a few rows can be added via the backend (service_role/SQL editor); the client works FINE with empty tables too (canonicalization is a no-op, the announcements section is hidden, the flag fallback is true).
