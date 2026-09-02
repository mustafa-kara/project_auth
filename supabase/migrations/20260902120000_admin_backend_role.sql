-- =============================================================================
-- Faz 6 ön koşulu: backend DB rolü (Desen B — NOLOGIN privilege-carrier).
-- Bu migration parola İÇERMEZ. Login'li bağlantı rolü operatör tarafından
-- Dashboard SQL editöründen oluşturulur ve bu role devredilir:
--   create role admin_app login password '<güçlü parola>';
--   grant admin_backend to admin_app;
-- Backend (Next.js) DATABASE_URL ile admin_app olarak bağlanır ve her çağrıda
--   begin; set local role admin_backend; select private.admin_global_stats(); commit;
-- Yalnızca 'private' şema USAGE + aggregate fonksiyon EXECUTE verilir; hiçbir
-- tabloya doğrudan yetki verilmez (E2E: ham satır/ciphertext okunamaz).
-- =============================================================================
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'admin_backend') then
    create role admin_backend nologin noinherit;
  end if;
end $$;

grant usage on schema private to admin_backend;
grant execute on function private.admin_global_stats() to admin_backend;

-- Savunma: private şeması ve fonksiyon Data API rollerine kapalı kalır.
revoke all on schema private from public, anon, authenticated;
revoke execute on function private.admin_global_stats() from public, anon, authenticated;
