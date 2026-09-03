# Supabase Project Info — authenticator-dev

> Development project. **All four migrations are applied**: the three 2026-06-06 ones (security scan CLEAN,
> 2026-06-06) and the Phase 6 `20260902201638_admin_backend_role.sql`, applied on **2026-09-02**.
> ⏳ What is still operator-only: the `sb_secret_…` key in `admin/.env.local` and the first
> `public.admin_users` row. The `admin_app` password **was set on 2026-09-02** and access path (a) was
> smoke-tested live the same day. The single canonical pending list is
> [Bekleyen operatör adımları (operator TODO)](#bekleyen-operatör-adımları-operator-todo) right below.

| Field | Value |
|---|---|
| Project name | `authenticator-dev` |
| Project ref | `vfyqokvgtdxxurroqbtj` |
| API URL | `https://vfyqokvgtdxxurroqbtj.supabase.co` |
| Region | `eu-central-1` |
| Postgres | 17.6 |
| Publishable key (client) | `sb_publishable_rxrL2mVbh1XgojMexy1cMw_Og8wE3xI` |

---

## Bekleyen operatör adımları (operator TODO)

The **single canonical list** of steps that still wait on a human. Every other document (`README.md`,
`admin/README.md`, `PLAN.md`, `CHANGELOG.md`) points here instead of keeping its own copy. State as of
**2026-09-02**.

- [ ] **`SUPABASE_SECRET_KEY` → `admin/.env.local`**
  *Where/how:* Dashboard → Settings → API Keys → copy the `sb_secret_…` key and paste it into the
  `SUPABASE_SECRET_KEY=` line of the git-ignored `admin/.env.local` (the file already exists locally with
  every other value filled in; this is the only placeholder left).
  *Unblocks:* the whole of access path (b) — `/users` (`auth.admin.listUsers` / ban / unban / delete), every
  write to `announcements` / `catalog_services` / `feature_flags`, and every `audit_logs` insert.
  *And the part that is easy to miss:* `requireAdmin()`'s fail-closed `admin_users` freshness lookup runs
  through that same secret-key client, so without this key **no signed-in page of the panel renders at all**.
  Precisely (read off `admin/src/lib/auth.ts`): submitting `/login` **succeeds** — `signInAction`
  (`admin/src/app/login/actions.ts`) only uses the publishable-key session client plus `isAdminClaims()` — but
  the redirect to `/` then hits the first `requireAdmin()` in the `(dashboard)` layout, whose
  `assertStillAdmin()` calls `createAdminClient()` → `getServerEnv()`, and that zod check throws a plain
  `Error` (`Geçersiz ortam değişkenleri (server): SUPABASE_SECRET_KEY: …`), **not** a `ForbiddenError`. So the
  user is not sent to `/forbidden`; they land on the `(dashboard)/error.tsx` boundary. Net effect: **you can
  sign in, but you cannot get into the panel.**
- [ ] **First real admin row**
  *Where/how:* register a real account in the mobile app (`auth.users` today holds only the UI-test account
  `uitest…@gmail.com`), take its uuid, then in Dashboard → SQL Editor:
  ```sql
  insert into public.admin_users (user_id) values ('<auth-user-uuid>');
  ```
  *Unblocks:* `/login`. Without a row here `public.custom_access_token_hook` never stamps
  `app_metadata.admin = true`, so every login is refused with "Bu hesap yönetici değil" — and the panel
  deliberately offers no UI for granting admin ([admin/README.md](../admin/README.md) §6).
- [ ] **Leaked password protection**
  *Where/how:* Dashboard → Authentication → Policies → turn on the HaveIBeenPwned check. Dashboard-only: it
  cannot be flipped over SQL or MCP.
  *Unblocks:* nothing in the panel — but the Supabase security advisor keeps returning the WARN *"Leaked
  Password Protection Disabled"* until it is on, so a clean advisor run needs it (Phase 7 item).
- [ ] **Rotate the `admin_app` password — recommended, not blocking**
  *Where/how:* the password in use today was transmitted in a chat, so treat it as burned. Dashboard → SQL
  Editor: `alter role admin_app password '<yeni-güçlü-parola>';`, then update the password inside
  `DATABASE_URL` in `admin/.env.local`. Nothing else in the repo references it.
  *Unblocks:* nothing — it closes a disclosure risk on a credential that already works.
- [ ] **The three pre-existing Dashboard items** — not repeated here, so there is only ever one wording: keep
  the `private` schema **out of** "Exposed schemas", turn email confirmation **ON** (Phase 3 Patch 1), and add
  the `dev.mustafakara.projectauth://login-callback` redirect URL (Phase 3 Patch 1). See the corresponding
  entries in the deployment checklist below.

**Already done, for contrast:** the migration, both DB roles, the bundled Postgres CA, and — since
**2026-09-02** — the `admin_app` password plus a live end-to-end smoke test of access path (a).

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

## Migrations (the applied ones align one-to-one with live — see migrations/README.md)
- `20260606152227_init_authenticator` — tables + RLS + hook + grant + trigger + publication + private aggregate
- `20260606152553_rls_initplan_optimization` — `auth.uid()` → `(select auth.uid())` (init-plan optimization; the audit FK index `idx_audit_logs_actor` was moved into the init migration, so it was removed from this file)
- `20260606162359_least_privilege_revoke` — revoke redundant `anon`/`authenticated` table privileges (defense in depth)
- `20260902201638_admin_backend_role` — **APPLIED 2026-09-02** (Phase 6): `admin_backend` NOLOGIN role + `private` USAGE + `admin_global_stats()` EXECUTE, with a defensive re-revoke from `public`/`anon`/`authenticated`. The live DB version is `20260902201638` and `list_migrations` returns exactly these four, matching the repo file names. See the deployment checklist below

## Security scan (get_advisors) — latest: 2026-09-02 (after the `admin_backend_role` DDL)
- **2026-09-02, re-run right after applying `20260902201638_admin_backend_role`: the DDL introduced NOTHING
  new.** The only security finding is the pre-existing WARN **"Leaked Password Protection Disabled"** — a
  Dashboard Auth setting (Authentication → Policies), which cannot be flipped over SQL or MCP; it is tracked
  as a Phase 7 item in [../PLAN.md](../PLAN.md).
- 2026-06-06 (after 0003): **security: 0 warnings** ✅
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

**Verified live (2026-09-02, for the Phase 6 admin panel):** `service_role` holds full grants on
`admin_users`, `audit_logs`, `announcements`, `catalog_services` and `feature_flags` — so the panel's
secret-key path (`auth.admin` + all writes + the `audit_logs` insert) works against this project **today**,
with no migration needed. The direct-Postgres aggregate path is no longer blocked either: the migration was
applied on 2026-09-02, the `admin_app` password was set the same day and the path was smoke-tested live (see
the checklist below).

**Verified live (2026-09-02, after applying `20260902201638_admin_backend_role`):**
| Role | Attributes | `private` USAGE | `admin_global_stats()` EXECUTE | `select` on `tokens` / `key_attributes` |
|---|---|---|---|---|
| `admin_backend` | NOLOGIN, NOINHERIT | ✅ | ✅ | **false** / **false** |
| `admin_app` | LOGIN (password set 2026-09-02), member of `admin_backend`, no `bypassrls`/`superuser`/`createrole` | via membership | via membership | **false** / **false** |

`admin_backend` holds **no table privileges at all** — it is a pure privilege carrier for the one aggregate
function, exactly as designed (ARCHITECTURE §6, Pattern B).

## Tables (all with RLS enabled)
admin_users · key_attributes · tokens · devices · announcements · catalog_services · feature_flags · audit_logs
+ `private.admin_global_stats()` (security definer, not exposed to the Data API)

## DEPLOYMENT CHECKLIST (manual steps — NOT part of the migrations)
- [x] Custom Access Token Hook enabled: Dashboard > Auth Hooks > "Customize Access Token (JWT) Claims" → Postgres → `public.custom_access_token_hook` ✅
- [x] Hook verified: admin→`{admin:true}`, normal→`{admin:false}` (see tests/TEST_REPORT.md) ✅
- [ ] Do NOT add the `private` schema to "Exposed schemas" (default; must not be added — just verify)
- [x] **Backend DB role + `private` USAGE + function EXECUTE grant** (ARCHITECTURE §6, Pattern B) —
  **migration `20260902201638_admin_backend_role.sql` APPLIED 2026-09-02**, and the login role `admin_app`
  was created by hand afterwards and granted `admin_backend`. Both roles were verified live the same day (see
  the privilege table above): `admin_backend` NOLOGIN + NOINHERIT with `private` USAGE and
  `admin_global_stats()` EXECUTE and **no table privileges**; `admin_app` LOGIN, member of `admin_backend`,
  no `bypassrls`/`superuser`/`createrole`; `has_table_privilege(… , 'select')` on `public.tokens` and
  `public.key_attributes` **false** for both. `execute` on `private.admin_global_stats()` remains denied to
  `anon`/`authenticated`, as designed.
- [x] **`admin_app` password — SET on 2026-09-02 by the operator**, in Dashboard → SQL Editor
  (`alter role admin_app password '<güçlü-parola>';`), never through a migration or this repo. That role is
  now `DATABASE_URL` in `admin/.env.local`. **The panel never connects as `postgres`**; it does
  `set local role admin_backend` inside the transaction ([admin/README.md](../admin/README.md) §1).
  **Access path (a) smoke-tested live the same day:** connected as `admin_app` to
  `aws-1-eu-central-1.pooler.supabase.com` on **both 6543 (transaction) and 5432 (session)** with verified TLS
  (the bundled CA below); inside `set local role admin_backend`, `select private.admin_global_stats()`
  returned the counts, while `select count(*) from public.tokens` was refused with **42501 permission
  denied** — exactly the designed shape.
- [ ] **Rotate the `admin_app` password (recommended).** The password set on 2026-09-02 was transmitted in a
  chat, so it should be treated as disclosed: `alter role admin_app password '<yeni-güçlü-parola>';` in
  Dashboard → SQL Editor, then update the password inside `DATABASE_URL` in `admin/.env.local`. Not blocking
  — see [Bekleyen operatör adımları](#bekleyen-operatör-adımları-operator-todo).
- [x] **Postgres CA for the panel's verified-TLS connection** — the Supabase Root 2021 CA (a public root
  certificate, not a secret) is bundled in the repo at `admin/certs/supabase-prod-ca-2021.crt`, with source
  URL, SHA-256 fingerprint and the shell one-liner that loads it into `SUPABASE_CA_CERT` in
  `admin/certs/README.txt`. Verified 2026-09-02:
  `openssl s_client -connect aws-1-eu-central-1.pooler.supabase.com:5432 -starttls postgres -CAfile admin/certs/supabase-prod-ca-2021.crt`
  → `Verify return code: 0 (ok)`. Fingerprint SHA-256
  `80:70:25:AD:50:D4:ED:21:9D:2C:9C:7D:29:9C:00:4F:82:4E:B0:0C:F7:F6:5A:FE:F6:07:D0:7B:72:E6:CA:FA`,
  validity 2021-04-28 → 2031-04-26.
- [ ] **`SUPABASE_SECRET_KEY` in `admin/.env.local`** — the `sb_secret_…` key is operator-only and is not
  written anywhere in this repo. `admin/.env.local` (git-ignored) already exists locally with the project URL,
  the publishable key, the CA cert and the now-complete `DATABASE_URL` filled in; the secret key is the only
  placeholder left. Without it you can submit `/login` successfully but **no signed-in page renders** — see
  [Bekleyen operatör adımları](#bekleyen-operatör-adımları-operator-todo) for the exact failure path.
- [ ] First **real** admin: `insert into public.admin_users (user_id) values ('<auth-user-uuid>');` (secure channel) — **still open as of 2026-09-02: no real account exists yet.** `auth.users` currently holds a single UI-test account (`uitest…@gmail.com`), so the step is: register a real account in the mobile app, take its uuid, then run the insert. **Required for the Phase 6 admin panel:** without a row here nobody gets past `/login`, and the panel deliberately offers no UI for granting admin (see [admin/README.md](../admin/README.md) §6).
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
