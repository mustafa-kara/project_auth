# Migrations

Supabase CLI migration geçmişi. Dosya adları canlı projedeki (`authenticator-dev`)
`supabase_migrations.schema_migrations` kayıtlarıyla **birebir** hizalıdır.

| Dosya | Ne yapar |
|---|---|
| `20260606152227_init_authenticator.sql` | İlk şema: 8 tablo + RLS + admin hook + trigger + Realtime + private aggregate |
| `20260606152553_rls_initplan_optimization.sql` | `auth.uid()` → `(select auth.uid())` (linter: auth_rls_initplan). FK index init'e taşındı (bkz. NOT). |
| `20260606162359_least_privilege_revoke.sql` | Fazlalık `anon`/`authenticated` table privilege'larını revoke (derinlemesine savunma) |

## Uygulama

- **Mevcut canlı projeye (`authenticator-dev`): hepsi ZATEN UYGULANMIŞ.** Tekrar push ETME.
- **Yeni/temiz bir projeye:** `supabase link` + `supabase db push` üç migration'ı sırayla uygular.

## Fresh-deploy DOĞRULANDI (2026-06-06)
Zincir, lokal Supabase CLI (`supabase start`) ile **sıfırdan bir Postgres'te** uygulandı —
üç migration da hatasız geçti (`Applying ... ✓`). Ardından güvenlik test betiği
([../tests/security_rls_tests.sql](../tests/security_rls_tests.sql)) bu fresh DB'de çalıştırıldı:
tüm testler geçti, privilege matrisi beklenen modelde. İki kez çalıştırıldı → idempotent.

## NOT
- `init` dosyası okunabilirlik için zengin yorumludur; DDL etkisi canlı kayıtla aynıdır.
- **FK covering index `idx_audit_logs_actor` artık `init` migration'ında** (§6) oluşturulur.
  Canlı projede bu index başlangıçta `initplan` adımında uygulanmıştı; yerel zincirde init'e
  taşındı. Bu yüzden `initplan` dosyasındaki `create index` satırı KALDIRILDI — aksi halde
  fresh deploy'da "relation idx_audit_logs_actor already exists" hatası verirdi.
