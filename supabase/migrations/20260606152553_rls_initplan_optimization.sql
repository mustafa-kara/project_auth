-- =============================================================================
-- RLS initplan optimizasyonu (Supabase linter: auth_rls_initplan)
-- =============================================================================
-- auth.uid() RLS policy'sinde doğrudan kullanılınca her satır için yeniden
-- değerlendirilir. (select auth.uid()) ile sarmalanınca planlayıcı bir kez
-- hesaplar (InitPlan). Davranış aynı, büyük tablolarda performans çok daha iyi.
-- Bkz. https://supabase.com/docs/guides/database/postgres/row-level-security#call-functions-with-select
-- =============================================================================

-- key_attributes
drop policy "owner reads key_attributes" on public.key_attributes;
drop policy "owner inserts key_attributes" on public.key_attributes;
drop policy "owner updates key_attributes" on public.key_attributes;
create policy "owner reads key_attributes" on public.key_attributes
  for select to authenticated using (user_id = (select auth.uid()));
create policy "owner inserts key_attributes" on public.key_attributes
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "owner updates key_attributes" on public.key_attributes
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- tokens
drop policy "owner reads tokens" on public.tokens;
drop policy "owner inserts tokens" on public.tokens;
drop policy "owner updates tokens" on public.tokens;
create policy "owner reads tokens" on public.tokens
  for select to authenticated using (user_id = (select auth.uid()));
create policy "owner inserts tokens" on public.tokens
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "owner updates tokens" on public.tokens
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- devices
drop policy "owner reads devices" on public.devices;
drop policy "owner inserts devices" on public.devices;
drop policy "owner updates devices" on public.devices;
drop policy "owner deletes devices" on public.devices;
create policy "owner reads devices" on public.devices
  for select to authenticated using (user_id = (select auth.uid()));
create policy "owner inserts devices" on public.devices
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "owner updates devices" on public.devices
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "owner deletes devices" on public.devices
  for delete to authenticated using (user_id = (select auth.uid()));

-- NOT: audit_logs FK covering index (idx_audit_logs_actor) ARTIK init migration'ında
-- oluşturuluyor (20260606152227 §6). Burada TEKRAR oluşturmak fresh deploy'da
-- "relation already exists" hatası verirdi → bu migration'dan kaldırıldı.
-- (Canlı projede bu index initplan adımında uygulanmıştı; yerel zincirde init'e taşındı.)
