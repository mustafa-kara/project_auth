# Migrations

Supabase CLI migration history. The file names are aligned **exactly** with the
`supabase_migrations.schema_migrations` records in the live project (`authenticator-dev`).

| File | What it does |
|---|---|
| `20260606152227_init_authenticator.sql` | Initial schema: 8 tables + RLS + admin hook + trigger + Realtime + private aggregate |
| `20260606152553_rls_initplan_optimization.sql` | `auth.uid()` → `(select auth.uid())` (linter: auth_rls_initplan). FK index moved into init (see NOTE). |
| `20260606162359_least_privilege_revoke.sql` | Revoke redundant `anon`/`authenticated` table privileges (defense in depth) |

## Applying

- **To the existing live project (`authenticator-dev`): all of them are ALREADY APPLIED.** Do NOT push again.
- **To a new/clean project:** `supabase link` + `supabase db push` applies the three migrations in order.

## Fresh-deploy VERIFIED (2026-06-06)
The chain was applied **from scratch on a clean Postgres** using the local Supabase CLI (`supabase start`) —
all three migrations passed without errors (`Applying ... ✓`). The security test script
([../tests/security_rls_tests.sql](../tests/security_rls_tests.sql)) was then run against this fresh DB:
all tests passed, and the privilege matrix matched the expected model. Run twice → idempotent.

## NOTE
- The `init` file is richly commented for readability; its DDL effect is the same as the live records.
- **The FK covering index `idx_audit_logs_actor` is now created in the `init` migration** (§6).
  In the live project this index was originally applied in the `initplan` step; in the local chain it was
  moved into init. For this reason the `create index` line in the `initplan` file was REMOVED — otherwise
  a fresh deploy would raise a "relation idx_audit_logs_actor already exists" error.
