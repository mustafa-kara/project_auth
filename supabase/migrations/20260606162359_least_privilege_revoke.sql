-- =============================================================================
-- 0003 — Least-privilege sertleştirme: gereksiz table privilege'larını REVOKE et
-- =============================================================================
-- NEDEN: Supabase'in public şema için kurduğu `pg_default_acl`, YENİ tablolara
-- otomatik olarak `anon` ve `authenticated` rollerine TAM privilege (arwdDxtm =
-- INSERT/SELECT/UPDATE/DELETE/...) veriyor. İlk migration'daki `grant select,
-- insert,update` satırları bu default'un ÜSTÜNE eklendiği için fazlalık
-- privilege'ları KALDIRMADI.
--
-- Sonuç (bu migration öncesi): RLS yazmayı blokluyordu (uçtan uca testle kanıtlı),
-- yani anlık güvenlik açığı YOKTU — ama "derinlemesine savunma" bozuktu: ileride
-- yanlış yazılmış GEVŞEK bir RLS policy'si table privilege engeli olmadığı için
-- doğrudan veri sızdırabilirdi. Bu migration ikinci katmanı (table-grant) geri kurar:
--   güvenlik = RLS (satır düzeyi)  +  table privilege (komut düzeyi).
--
-- TASARIM: revoke ALL → sonra yalnızca gerekeni yeniden grant et (açık, idempotent).
-- service_role'a DOKUNULMAZ (backend RLS bypass'ı buna dayanır).
-- =============================================================================

-- USER tabloları: anon hiçbir şey yapamaz; authenticated yalnızca RLS'li CRUD.
revoke all on table public.key_attributes from anon, authenticated;
grant select, insert, update on table public.key_attributes to authenticated;

revoke all on table public.tokens from anon, authenticated;
grant select, insert, update on table public.tokens to authenticated;   -- DELETE yok (soft delete)

revoke all on table public.devices from anon, authenticated;
grant select, insert, update, delete on table public.devices to authenticated;

revoke all on table public.audit_logs from anon, authenticated;
grant select on table public.audit_logs to authenticated;               -- RLS is_admin() ile kısıtlı

revoke all on table public.admin_users from anon, authenticated;        -- hiçbir Data API rolü erişemez

-- ADMIN-PUBLIC tabloları: yalnızca SELECT; yazma server-side secret key (service_role) ile.
revoke all on table public.announcements   from anon, authenticated;
grant select on table public.announcements   to anon, authenticated;

revoke all on table public.catalog_services from anon, authenticated;
grant select on table public.catalog_services to anon, authenticated;

revoke all on table public.feature_flags    from anon, authenticated;
grant select on table public.feature_flags    to anon, authenticated;

-- GELECEK tablolar için default'u daralt: yeni public objelerde anon/authenticated
-- otomatik TAM yetki ALMASIN. Bundan sonra her tablo ihtiyacı kadar explicit grant alır.
--
-- ÖNEMLİ KISIT (lokal Postgres'te doğrulandı): `alter default privileges` YALNIZCA
-- komutu çalıştıran rolün (burada `postgres`) sahip olacağı objeleri etkiler.
-- Supabase'de `supabase_admin` rolünün AYRI bir geniş default ACL'i vardır
-- (anon/authenticated = arwdDxtm) ve migration onu DEĞİŞTİREMEZ
-- (`alter default privileges for role supabase_admin ...` → "permission denied").
-- SONUÇ → DİSİPLİN KURALI: tüm public tablolar migration ile (yani `postgres`
-- rolüyle) oluşturulmalı. Dashboard/SQL editöründe `supabase_admin` ile tablo
-- OLUŞTURMA — aksi halde anon/authenticated'a fazla privilege geri gelir ve onu
-- yine açık `revoke` ile temizlemen gerekir.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;
