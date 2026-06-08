# Supabase Proje Bilgileri — authenticator-dev

> Geliştirme projesi. Migration uygulandı + güvenlik taraması TEMİZ (2026-06-06).

| Alan | Değer |
|---|---|
| Proje adı | `authenticator-dev` |
| Project ref | `vfyqokvgtdxxurroqbtj` |
| API URL | `https://vfyqokvgtdxxurroqbtj.supabase.co` |
| Bölge | `eu-central-1` |
| Postgres | 17.6 |
| Publishable key (client) | `sb_publishable_rxrL2mVbh1XgojMexy1cMw_Og8wE3xI` |

## Client kullanımı (Flutter)
```dart
await Supabase.initialize(
  url: 'https://vfyqokvgtdxxurroqbtj.supabase.co',
  // 'publishableKey' parametresi (eski 'anonKey' DEĞİL).
  publishableKey: 'sb_publishable_rxrL2mVbh1XgojMexy1cMw_Og8wE3xI',
);
```
> Notlar:
> - **API doğrulandı** — kurulu `supabase_flutter 2.14.1` kaynağında (`lib/src/supabase.dart`)
>   `initialize({required String url, String? publishableKey, @Deprecated(...) String? anonKey, ...})`.
>   Yani `publishableKey:` GERÇEK parametredir (compile'da takılmaz) ve `anonKey` artık
>   **`@Deprecated`** ("will be removed in a future major version"). Bazı online quickstart/pub.dev
>   doküman sayfaları hâlâ `anonKey`'e publishable key veriyor — bunlar güncel paketin gerisinde;
>   nihai otorite kurulu paketin imzasıdır. `publishableKey:` hem doğru hem gelecek-uyumlu.
> - Secret key (`sb_secret_...`) buraya YAZILMAZ — yalnızca backend (Next.js admin / Edge Function). Dashboard > Settings > API Keys'ten alınır, env'de tutulur.
> - Key'i koda gömme; `--dart-define` / env ile geç (publishable düşük yetkili olsa da iyi pratik).

## Uygulanan migration'lar (canlıyla birebir hizalı — bkz. migrations/README.md)
- `20260606152227_init_authenticator` — tablolar + RLS + hook + grant + trigger + publication + private aggregate
- `20260606152553_rls_initplan_optimization` — `auth.uid()` → `(select auth.uid())` (init-plan optimizasyonu; audit FK index `idx_audit_logs_actor` init migration'ına taşındığı için bu dosyadan kaldırıldı)
- `20260606162359_least_privilege_revoke` — fazlalık `anon`/`authenticated` table privilege'larını revoke (derinlemesine savunma)

## Güvenlik taraması (get_advisors) — son: 2026-06-06 (0003 sonrası)
- **security: 0 uyarı** ✅
- performance: yalnızca 1× `unused_index` (`idx_audit_logs_created`, INFO — boş DB; tasarımsal index korunuyor)

## Privilege modeli (0003 sonrası — derinlemesine savunma)
`anon`/`authenticated` rolleri yalnızca ihtiyaç duyulan table privilege'a sahip:
| Tablo | anon | authenticated |
|---|---|---|
| announcements / catalog_services / feature_flags | SELECT | SELECT |
| tokens / key_attributes | — | SELECT, INSERT, UPDATE |
| devices | — | SELECT, INSERT, UPDATE, DELETE |
| audit_logs | — | SELECT (RLS `is_admin()`) |
| admin_users | — | — |
Yazma/yetkili işlemler yalnızca `service_role` (backend secret key, RLS bypass). RLS + table-grant = iki katman.

## Tablolar (hepsi RLS açık)
admin_users · key_attributes · tokens · devices · announcements · catalog_services · feature_flags · audit_logs
+ `private.admin_global_stats()` (security definer, Data API'ye expose değil)

## DEPLOYMENT CHECKLIST (manuel adımlar — migration kapsamında DEĞİL)
- [x] Custom Access Token Hook etkinleştirildi: Dashboard > Auth Hooks > "Customize Access Token (JWT) Claims" → Postgres → `public.custom_access_token_hook` ✅
- [x] Hook doğrulandı: admin→`{admin:true}`, normal→`{admin:false}` (bkz. tests/TEST_REPORT.md) ✅
- [ ] `private` şemayı "Exposed schemas"a EKLEME (varsayılan; eklenmemeli — sadece kontrol et)
- [ ] Backend DB rolü + `private` USAGE + fonksiyon EXECUTE grant (ARCHITECTURE §6, migration Desen A/B) — Faz 6 öncesi
- [ ] İlk **gerçek** admin: `insert into public.admin_users (user_id) values ('<auth-user-uuid>');` (güvenli kanal) — gerçek kullanıcı oluşunca
- [ ] **Faz 3 Patch 1 — E-posta onayı:** Dashboard > Auth > Providers > Email → "Confirm email" AÇIK (kayıt sonrası onay maili).
- [ ] **Faz 3 Patch 1 — Redirect URL:** Dashboard > Auth > URL Configuration > Redirect URLs → `dev.mustafakara.projectauth://login-callback` ekle (PKCE deep-link callback; native intent-filter/URL scheme ile eşleşir).
