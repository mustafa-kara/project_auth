-- =============================================================================
-- Authenticator App — Faz 3 ilk şema migration'ı
-- E2E şifreli TOTP authenticator: tablolar + RLS + admin hook + senkron + admin aggregate
-- Mimari: ARCHITECTURE.md (§5, §6). Adım sırası: create → enable RLS → policy → grant.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Özel (Data API'ye expose EDİLMEYEN) şema — admin aggregate fonksiyonları için.
--    Bu şema "Exposed schemas" listesine EKLENMEZ; fonksiyonlar yalnızca
--    server-side doğrudan Postgres bağlantısıyla çağrılır (supabase-js .rpc() ile DEĞİL).
-- -----------------------------------------------------------------------------
create schema if not exists private;

-- =============================================================================
-- 1. ADMIN İŞARETİ + CUSTOM ACCESS TOKEN HOOK
-- =============================================================================

-- 1a. Admin kullanıcıları (auth.users'a doğrudan yazmak yerine ayrı tablo)
create table public.admin_users (
  user_id uuid primary key references auth.users on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admin_users enable row level security;
-- Normal kullanıcılar için hiçbir policy yok → client erişemez.

-- 1b. Custom Access Token Hook: admin kullanıcının access token'ına app_metadata.admin=true ekler.
--     NOT: Dashboard > Auth > Hooks > "Custom Access Token" ile bu fonksiyon etkinleştirilmeli.
create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  claims jsonb;
  is_admin boolean;
begin
  select exists(
    select 1 from public.admin_users a where a.user_id = (event->>'user_id')::uuid
  ) into is_admin;

  claims := event->'claims';
  if jsonb_typeof(claims->'app_metadata') is null then
    claims := jsonb_set(claims, '{app_metadata}', '{}');
  end if;
  claims := jsonb_set(claims, '{app_metadata, admin}', to_jsonb(is_admin));

  return jsonb_set(event, '{claims}', claims);
end;
$$;

-- 1c. Hook izinleri (HEPSİ ZORUNLU — eksikse claim hep false kalır):
grant usage on schema public to supabase_auth_admin;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from authenticated, anon, public;

grant select on table public.admin_users to supabase_auth_admin;
revoke all on table public.admin_users from authenticated, anon, public;

-- 1d. RLS açıkken grant tek başına YETMEZ — supabase_auth_admin'e SELECT policy gerekir,
--     yoksa hook admin_users satırını göremez ve claim HER ZAMAN false döner.
create policy "auth admin reads admin_users"
  on public.admin_users
  as permissive for select
  to supabase_auth_admin
  using (true);

-- 1e. RLS politikalarında kullanılacak yardımcı: is_admin()
create or replace function public.is_admin()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'admin')::boolean, false);
$$;

-- =============================================================================
-- 2. KULLANICI KRİPTO METADATASI (E2E — sunucu açık anahtar görmez)
-- =============================================================================
create table public.key_attributes (
  user_id uuid primary key references auth.users on delete cascade,
  kdf_salt bytea not null,                       -- Argon2id salt
  kdf_ops int not null,                          -- Argon2id opsLimit
  kdf_mem int not null,                          -- Argon2id memLimit
  encrypted_master_key bytea not null,           -- KEK ile sarmalı master key
  master_key_nonce bytea not null,
  recovery_encrypted_master_key bytea not null,  -- recovery key ile sarmalı master key
  recovery_nonce bytea not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.key_attributes enable row level security;

-- NOT: auth.uid() yerine (select auth.uid()) — initplan optimizasyonu (her satırda yeniden
-- değerlendirilmesini önler; Supabase linter auth_rls_initplan). Bkz docs RLS#call-functions-with-select.
create policy "owner reads key_attributes" on public.key_attributes
  for select to authenticated using (user_id = (select auth.uid()));
create policy "owner inserts key_attributes" on public.key_attributes
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "owner updates key_attributes" on public.key_attributes
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- GRANT (RLS policy doğru olsa bile table privilege yoksa 42501 permission denied)
grant select, insert, update on table public.key_attributes to authenticated;
grant all on table public.key_attributes to service_role;

-- =============================================================================
-- 3. ŞİFRELİ TOTP GİRDİLERİ (E2E — ciphertext sunucu için opak blob)
-- =============================================================================
create table public.tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  ciphertext bytea not null,        -- XChaCha20-Poly1305(token JSON)
  nonce bytea not null,
  version int not null default 1,   -- şema/şifreleme versiyonu
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),  -- server-side trigger ile set edilir
  deleted boolean not null default false           -- soft delete (senkron tutarlılığı)
);
alter table public.tokens enable row level security;

create policy "owner reads tokens" on public.tokens
  for select to authenticated using (user_id = (select auth.uid()));
create policy "owner inserts tokens" on public.tokens
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "owner updates tokens" on public.tokens
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
-- Not: gerçek DELETE yok; silme = update deleted=true (soft delete).

-- GRANT — delete bilinçli olarak verilmiyor (soft delete kullanılıyor)
grant select, insert, update on table public.tokens to authenticated;
grant all on table public.tokens to service_role;

-- Senkron pull performansı için index
create index idx_tokens_user_updated on public.tokens (user_id, updated_at);

-- =============================================================================
-- 4. CİHAZLAR (çoklu cihaz + FCM push token)
-- =============================================================================
create table public.devices (
  user_id uuid not null references auth.users on delete cascade,
  device_id text not null,
  name text,
  last_seen timestamptz,
  push_token text,
  created_at timestamptz not null default now(),
  primary key (user_id, device_id)
);
alter table public.devices enable row level security;

create policy "owner reads devices" on public.devices
  for select to authenticated using (user_id = (select auth.uid()));
create policy "owner inserts devices" on public.devices
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "owner updates devices" on public.devices
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "owner deletes devices" on public.devices
  for delete to authenticated using (user_id = (select auth.uid()));

-- GRANT
grant select, insert, update, delete on table public.devices to authenticated;
grant all on table public.devices to service_role;

-- =============================================================================
-- 5. ADMIN-PUBLIC TABLOLAR (herkes okur, sadece admin yazar)
-- =============================================================================
create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null,
  audience text not null default 'all',
  created_at timestamptz not null default now()
);
alter table public.announcements enable row level security;
-- Login öncesi de okunabilir (anon + authenticated). YAZMA: yalnızca server-side secret key
-- (service_role RLS'i bypass eder) → ayrı write policy GEREKMEZ, authenticated'a write grant YOK.
create policy "anyone reads announcements" on public.announcements
  for select to anon, authenticated using (true);

grant select on table public.announcements to anon, authenticated;
grant all on table public.announcements to service_role;

create table public.catalog_services (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  issuer text,
  logo_url text
);
alter table public.catalog_services enable row level security;
create policy "anyone reads catalog" on public.catalog_services
  for select to anon, authenticated using (true);
-- YAZMA: server-side secret key (yukarıdaki announcements ile aynı model)

grant select on table public.catalog_services to anon, authenticated;
grant all on table public.catalog_services to service_role;

create table public.feature_flags (
  key text primary key,
  enabled boolean not null default false,
  payload jsonb,
  updated_at timestamptz not null default now()
);
alter table public.feature_flags enable row level security;
create policy "anyone reads feature_flags" on public.feature_flags
  for select to anon, authenticated using (true);
-- YAZMA: server-side secret key (yukarıdaki announcements ile aynı model)

grant select on table public.feature_flags to anon, authenticated;
grant all on table public.feature_flags to service_role;

-- =============================================================================
-- 6. AUDIT LOGS (sadece admin okur; insert server-side secret key/Edge Function)
-- =============================================================================
create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor uuid references auth.users on delete set null,
  action text not null,
  target text,
  created_at timestamptz not null default now()
);
alter table public.audit_logs enable row level security;
create policy "admin reads audit_logs" on public.audit_logs
  for select to authenticated using (public.is_admin());
-- INSERT için policy YOK → normal client yazamaz; insert backend secret key ile (RLS bypass).

-- GRANT: authenticated yalnızca SELECT (üstelik policy is_admin() ile kısıtlı); insert/all backend'de
grant select on table public.audit_logs to authenticated;
grant all on table public.audit_logs to service_role;

create index idx_audit_logs_created on public.audit_logs (created_at);
create index idx_audit_logs_actor on public.audit_logs (actor);  -- FK covering index (linter: unindexed_foreign_keys)

-- =============================================================================
-- 7. SENKRON: server-side updated_at trigger + Realtime publication
-- =============================================================================
-- 7a. updated_at güvenini client'a bırakma — server now() ile set et (clock skew engellenir).
--     İKİ AYRI fonksiyon: created_at olan tablolar vs sadece updated_at olan tablolar.
--     (Tek fonksiyonda 'new.created_at := now()' yapmak, created_at'ı olmayan tabloda
--      'record "new" has no field "created_at"' runtime hatası verir.)

-- created_at + updated_at olan tablolar için (tokens, key_attributes)
create or replace function public.touch_timestamps()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (tg_op = 'INSERT') then
    new.created_at := now();
  end if;
  new.updated_at := now();
  return new;
end;
$$;

-- yalnızca updated_at olan tablolar için (feature_flags)
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger trg_tokens_touch
  before insert or update on public.tokens
  for each row execute procedure public.touch_timestamps();

create trigger trg_key_attributes_touch
  before insert or update on public.key_attributes
  for each row execute procedure public.touch_timestamps();

-- feature_flags: created_at yok → yalnızca updated_at set eden fonksiyon
create trigger trg_feature_flags_touch
  before insert or update on public.feature_flags
  for each row execute procedure public.touch_updated_at();

-- 7b. Realtime: tokens değişiklikleri yayınlansın (RLS'e tabi — kullanıcı yalnız kendi olaylarını alır)
alter publication supabase_realtime add table public.tokens;

-- =============================================================================
-- 8. ADMIN CROSS-USER AGGREGATE — özel şemada, security definer
--    Çağırma: SADECE server-side doğrudan Postgres bağlantısı ile (Data API'den DEĞİL).
--    E2E: yalnızca SAYIM/metadata döner; ham ciphertext/satır ASLA dönmez.
-- =============================================================================
create or replace function private.admin_global_stats()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'total_users',  (select count(*) from auth.users),
    'total_tokens', (select count(*) from public.tokens where deleted = false),
    'total_devices',(select count(*) from public.devices),
    'generated_at', now()
  );
$$;

-- Guardrail: bu fonksiyon Data API'ye / normal rollere AÇIK BIRAKILMAZ.
-- Normal Data API rolleri 'private' şemayı zaten görmemeli; yine de açıkça revoke ediyoruz.
revoke all on schema private from public, anon, authenticated;
revoke execute on function private.admin_global_stats() from public, anon, authenticated;

-- grant: backend'in kullandığı DB rolüne HEM şema USAGE HEM fonksiyon EXECUTE gerekir
-- (ikisi birlikte; biri eksikse 'select private.admin_global_stats()' yetkide takılır).
--
-- Üretim deployment'ında iki geçerli desen (NOLOGIN role ile DOĞRUDAN bağlanılamaz!):
--   Desen A — doğrudan login rolü:
--     create role admin_backend login password '...';   -- bağlantı bu rolle yapılır
--     grant usage on schema private to admin_backend;
--     grant execute on function private.admin_global_stats() to admin_backend;
--     -- DATABASE_URL bu login rolünü kullanır.
--   Desen B — privilege (NOLOGIN) role + SET ROLE:
--     create role admin_backend nologin;                -- yalnızca yetki taşıyıcı
--     grant usage on schema private to admin_backend;
--     grant execute on function private.admin_global_stats() to admin_backend;
--     grant admin_backend to <login_role>;              -- login'li bağlantı rolüne devret
--     -- bağlantıda: SET ROLE admin_backend; select private.admin_global_stats();
-- (Bu migration rolü OLUŞTURMUYOR — login/şifre yönetimi deployment kararı; NOT'a bak.)

-- =============================================================================
-- DEPLOYMENT CHECKLIST (bu migration'da KASITLI olarak YAPILMAYANLAR — ayrı adımlar):
--  [ ] Custom Access Token Hook'u Dashboard > Auth > Hooks'tan etkinleştir (SQL ile değil).
--  [ ] 'private' şemayı "Exposed schemas" listesine EKLEME (varsayılan; eklenmemeli).
--  [ ] Backend DB rolü (yukarıdaki Desen A veya B) + 'private' şemaya USAGE + fonksiyona EXECUTE grant.
--      Desen A: LOGIN'li rol → DATABASE_URL doğrudan bu rolle bağlanır.
--      Desen B: NOLOGIN privilege role → login'li bağlantı rolüne `grant admin_backend to <login_role>`,
--               bağlantıda `SET ROLE admin_backend`. (NOLOGIN role ile DOĞRUDAN bağlanılamaz.)
--  [ ] İlk admin kullanıcıyı admin_users'a ekle (manuel/güvenli kanal).
--  [ ] Migration uygulandıktan sonra get_advisors (security) ile linter taraması yap.
-- =============================================================================
