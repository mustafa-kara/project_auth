# Security & RLS Test Report — authenticator-dev

> **Date:** 2026-06-06
> **Project:** authenticator-dev (`vfyqokvgtdxxurroqbtj`), Postgres 17.6, eu-central-1
> **Migrations:** `20260606152227_init_authenticator` + `20260606152553_rls_initplan_optimization` + `20260606162359_least_privilege_revoke`
> **Method:** End-to-end execution against the real database (Supabase MCP `execute_sql`)
> **Repro script:** [`security_rls_tests.sql`](security_rls_tests.sql)

---

## Summary

| Layer | Result |
|---|---|
| Migration application | ✅ no runtime errors |
| `get_advisors` (security) | ✅ **0 warnings** |
| `get_advisors` (performance) | ✅ initplan WARN fixed (remaining: misleading `unused_index` INFO) |
| End-to-end behavior tests | ✅ **8/8 passed** |

---

## Automated linter results (`get_advisors`)

### Security: clean
```
{ "lints": [] }
```
Zero security warnings — **no** missing RLS policy, exposed `security definer`, incorrect hook permission, etc.

### Performance: 1 real WARN found and fixed
- **`auth_rls_initplan` (11 policies)** — in RLS, `auth.uid()` was being re-evaluated for every row.
  - **Fix:** `auth.uid()` → `(select auth.uid())` in all policies (migration `rls_initplan_optimization`).
  - **Result:** on the rescan the WARN was **gone.**
- **`unindexed_foreign_keys` (`audit_logs.actor`)** — FK covering index added (`idx_audit_logs_actor`).
- **`unused_index` (INFO)** — Misleading: because no queries ran against the empty DB. The indexes are by design (sync pull, audit ordering, FK covering); **kept**, no action required. (On the latest scan, only `idx_audit_logs_created` is reported.)

### Additional hardening — least-privilege (migration `0003_least_privilege_revoke`, 2026-06-06)
Noticed afterward: Supabase's `pg_default_acl` was granting FULL privileges to `anon`/`authenticated` on new public tables (even though RLS blocked them, the defense in depth was missing). The redundant privileges were revoked; after the revoke the security advisor still reports **0 warnings**. For the final privilege matrix, see [PROJECT_INFO.md](../PROJECT_INFO.md) → Privilege model.

> **Note:** `auth_rls_initplan` was a finding that fourteen rounds of theoretical review missed and only the real linter caught — it shows the value of an actual run.

### Fresh-deploy + idempotency verification (local Supabase CLI, 2026-06-06)
The migration chain was applied **from scratch on a local Postgres** (`supabase start`): all three migrations
passed without errors. ALL of the behavior tests below were run against this fresh DB and passed; the script was
also run **twice** → on the second run TEST 3 still reported `count=1` (idempotent thanks to fixed token ids).
This closed two findings from the external review:
> - **(high)** `idx_audit_logs_actor` was being created twice across two migrations → would raise
>   "already exists" on a fresh deploy. It was removed from the `initplan` file; the fresh deploy is now error-free (proven).
> - **(low)** The test script claimed to be "idempotent" but the token inserts had no fixed `id`. Fixed
>   ids were added; idempotency was actually verified by running it twice.

---

## End-to-end behavior tests

Test setup: 2 test users — one in `admin_users` (admin), one normal (control group). RLS behavior was tested by simulating a real user context with `set local role authenticated` + `request.jwt.claims`.

| # | Test | Expected | Observed | Status |
|---|---|---|---|---|
| 1a | Hook — admin user | `app_metadata = {admin: true}` | `{admin: true}` | ✅ |
| 1b | Hook — normal user | `app_metadata = {admin: false}` | `{admin: false}` | ✅ |
| 2 | `is_admin()` with admin claim | `true` | `true` | ✅ |
| 3 | Cross-user RLS isolation | User 2 sees only their own token (1); does not see the other's | `visible=1, can_see_other=false` | ✅ |
| 4 | `with check` — insert on behalf of another | Rejected; user1 token count stays at 1 | insert blocked, count=1 | ✅ |
| 5a | `audit_logs` — admin reads | Sees it (1) | 1 | ✅ |
| 5b | `audit_logs` — non-admin | Does not see it (0) | 0 | ✅ |
| 6 | FK cascade + cleanup | When the user is deleted, token+admin cascade; all 0 | all 0 | ✅ |

---

## Most critical verification

**The `supabase_auth_admin` SELECT policy was genuinely necessary and works.**
The risk debated theoretically over fourteen rounds: "if the hook cannot read RLS-protected `admin_users`, the claim stays **always false**." The real test (1a/1b) proved the hook produces `true`/`false` **correctly** → the policy is set up correctly.

**E2E isolation proven.** Test 3: one user cannot see another user's (encrypted) token row even at the database level. Test 4: cannot write on behalf of another.

---

## Re-running

```bash
# with psql
psql "$DATABASE_URL" -f supabase/tests/security_rls_tests.sql

# or block by block with the Supabase MCP execute_sql
```
The script is idempotent; it creates its own test data and cleans up at the end (fixed test UUIDs, does not touch production data).

## End-to-end hook verification — REAL login flow (local CLI, 2026-06-06)
The earlier tests called the hook *function* directly. With `[auth.hook.custom_access_token]` enabled in
`config.toml`, the local stack (including GoTrue) was started and the **full auth pipeline** was tested:
- signup → add to `admin_users` → **real `signin` (password grant)** → decode the returned JWT:
  `app_metadata.admin = true` ✅
- normal user (not admin) → JWT `app_metadata.admin = false` ✅ (negative control)
- Test users deleted at the end (0 residue).

This proves the hook works not only in the function logic but also during **real token generation after login**.
(In the live project the hook is enabled from the Dashboard; locally it is enabled via `config.toml`.)

## What this report does NOT COVER (to be added later)
- Realtime publication behavior (subscribe-before bootstrap, arrival-order LWW) — requires a real client.
- New secret key `apikey` header / `verify_jwt=false` (Edge Function) — once the backend is set up.
- `private.admin_global_stats()` direct-connection + DB role grant test — once the backend role is set up.
