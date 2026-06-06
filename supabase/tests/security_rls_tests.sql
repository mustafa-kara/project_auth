-- =============================================================================
-- Güvenlik & RLS uçtan uca test betiği — authenticator-dev
-- =============================================================================
-- AMAÇ: migration zincirinin (init + rls_initplan + least_privilege) güvenlik
--       davranışını gerçek DB'de doğrular. Hook (app_metadata.admin), is_admin(),
--       cross-user RLS izolasyonu, with check, audit_logs admin erişimi, FK cascade.
--
-- ÇALIŞTIRMA:
--   * MCP: execute_sql ile blok blok (transaction kontrolü için), VEYA
--   * psql:  psql "$DATABASE_URL" -f security_rls_tests.sql
--
-- ÖN KOŞUL: Custom Access Token Hook Dashboard'dan etkinleştirilmiş olmalı
--           (hook FONKSİYONU bu betikte doğrudan çağrıldığı için fonksiyon mantığı
--            hook etkin olmasa da test edilir; ama gerçek login akışı için hook şart).
--
-- NOT: Betik kendi test verisini oluşturur ve SONUNDA temizler. Üretim verisine
--      dokunmaz (sabit test UUID'leri kullanır). İdempotent (on conflict do nothing).
-- =============================================================================

-- Sabit test kimlikleri
\set admin_uid  '11111111-1111-1111-1111-111111111111'
\set normal_uid '22222222-2222-2222-2222-222222222222'

-- -----------------------------------------------------------------------------
-- KURULUM: iki test kullanıcısı; biri admin
-- -----------------------------------------------------------------------------
insert into auth.users (id, email, instance_id, aud, role) values
  ('11111111-1111-1111-1111-111111111111', 'admin-test@example.com',  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated'),
  ('22222222-2222-2222-2222-222222222222', 'normal-test@example.com', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated')
on conflict (id) do nothing;

insert into public.admin_users (user_id)
values ('11111111-1111-1111-1111-111111111111')
on conflict (user_id) do nothing;

-- =============================================================================
-- TEST 1 — Custom Access Token Hook: claim doğru set ediliyor mu?
-- Beklenen: admin → {"admin": true},  normal → {"admin": false}
-- =============================================================================
select 'TEST 1a (admin hook claim)' as test,
       public.custom_access_token_hook(jsonb_build_object(
         'user_id','11111111-1111-1111-1111-111111111111',
         'claims', jsonb_build_object('sub','11111111-1111-1111-1111-111111111111','role','authenticated')
       )) -> 'claims' -> 'app_metadata' as got,
       '{"admin": true}'::jsonb as expected;

select 'TEST 1b (normal hook claim)' as test,
       public.custom_access_token_hook(jsonb_build_object(
         'user_id','22222222-2222-2222-2222-222222222222',
         'claims', jsonb_build_object('sub','22222222-2222-2222-2222-222222222222','role','authenticated')
       )) -> 'claims' -> 'app_metadata' as got,
       '{"admin": false}'::jsonb as expected;

-- =============================================================================
-- TEST 2 — is_admin() JWT claim'e göre doğru dönüyor mu?
-- Beklenen: admin claim → true
-- =============================================================================
begin;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","app_metadata":{"admin":true}}';
  select 'TEST 2 (is_admin admin claim)' as test, public.is_admin() as got, true as expected;
commit;

-- =============================================================================
-- TEST 3 — Cross-user RLS izolasyonu (E2E'nin kalbi)
-- Kurulum: her iki kullanıcıya birer token (service_role ile, RLS bypass)
-- Beklenen: kullanıcı 2 yalnızca KENDİ token'ını görür (1), kullanıcı 1'inkini görmez
-- =============================================================================
-- SABİT id'ler (idempotentlik için): betik yarıda kalıp tekrar çalışsa bile
-- on conflict (id) bu satırlara çarpar → duplicate test token'ı oluşmaz, count=1 korunur.
insert into public.tokens (id, user_id, ciphertext, nonce) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '\xdeadbeef', '\x01'),
  ('aaaaaaaa-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', '\xcafebabe', '\x02')
on conflict (id) do nothing;

begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
  select 'TEST 3 (cross-user RLS)' as test,
         count(*) as visible_to_user2,                                            -- beklenen: 1
         bool_or(user_id = '11111111-1111-1111-1111-111111111111') as can_see_other -- beklenen: false
  from public.tokens;
commit;

-- =============================================================================
-- TEST 4 — with check: başkası adına insert engellenmeli
-- Beklenen: insert RLS ihlaliyle reddedilir → kullanıcı 1 token sayısı 1'de kalır
-- =============================================================================
-- NOT: 'set local role' do-bloğu içinde beklendiği gibi çalışmaz; do bloğu içinde
--      set_config(..., is_local=true) kullanıyoruz (doğrulandı).
do $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
  insert into public.tokens (user_id, ciphertext, nonce)
  values ('11111111-1111-1111-1111-111111111111', '\xff', '\x09');
  raise notice 'TEST 4 FAIL: with check engellemedi!';
exception
  when insufficient_privilege or check_violation then
    raise notice 'TEST 4 PASS: with check engelledi (%)', sqlerrm;
end $$;
reset role;
-- Doğrulama: kullanıcı 1 hâlâ tek token (service_role görünümü)
select 'TEST 4 (with check sonrası user1 token)' as test,
       count(*) as got, 1 as expected
from public.tokens where user_id = '11111111-1111-1111-1111-111111111111';

-- =============================================================================
-- TEST 5 — audit_logs: yalnızca admin okur
-- Beklenen: admin claim → 1 satır görür, normal → 0 satır
-- =============================================================================
insert into public.audit_logs (actor, action, target) values (null, 'test.action', 'test');

begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated","app_metadata":{"admin":true}}';
  select 'TEST 5a (admin audit görür)' as test, count(*) as got, 1 as expected from public.audit_logs;
commit;

begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
  select 'TEST 5b (non-admin audit görmez)' as test, count(*) as got, 0 as expected from public.audit_logs;
commit;

-- =============================================================================
-- TEMİZLİK — test verisini sil (FK cascade: tokens + admin_users otomatik gider)
-- =============================================================================
delete from public.audit_logs where action = 'test.action';
delete from auth.users where id in (
  '11111111-1111-1111-1111-111111111111',
  '22222222-2222-2222-2222-222222222222'
);

-- TEST 6 — FK cascade doğrulaması: hepsi 0 olmalı
select 'TEST 6 (temizlik + cascade)' as test,
       (select count(*) from auth.users where email like '%-test@example.com') as kalan_user,    -- 0
       (select count(*) from public.tokens) as kalan_token,                                       -- 0
       (select count(*) from public.admin_users) as kalan_admin,                                  -- 0
       (select count(*) from public.audit_logs) as kalan_audit;                                   -- 0
