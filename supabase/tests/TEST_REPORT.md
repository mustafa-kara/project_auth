# Güvenlik & RLS Test Raporu — authenticator-dev

> **Tarih:** 2026-06-06
> **Proje:** authenticator-dev (`vfyqokvgtdxxurroqbtj`), Postgres 17.6, eu-central-1
> **Migration:** `20260606152227_init_authenticator` + `20260606152553_rls_initplan_optimization` + `20260606162359_least_privilege_revoke`
> **Yöntem:** Gerçek veritabanında uçtan uca çalıştırma (Supabase MCP `execute_sql`)
> **Tekrar betiği:** [`security_rls_tests.sql`](security_rls_tests.sql)

---

## Özet

| Katman | Sonuç |
|---|---|
| Migration uygulaması | ✅ runtime hatası yok |
| `get_advisors` (security) | ✅ **0 uyarı** |
| `get_advisors` (performance) | ✅ initplan WARN düzeltildi (kalan: yanıltıcı `unused_index` INFO) |
| Uçtan uca davranış testleri | ✅ **8/8 geçti** |

---

## Otomatik linter sonuçları (`get_advisors`)

### Security: temiz
```
{ "lints": [] }
```
Sıfır güvenlik uyarısı — eksik RLS policy, exposed `security definer`, hatalı hook izni vb. **yok**.

### Performance: 1 gerçek WARN bulundu ve düzeltildi
- **`auth_rls_initplan` (11 policy)** — RLS'te `auth.uid()` her satır için yeniden değerlendiriliyordu.
  - **Düzeltme:** tüm policy'lerde `auth.uid()` → `(select auth.uid())` (migration `rls_initplan_optimization`).
  - **Sonuç:** tekrar taramada WARN **gitti.**
- **`unindexed_foreign_keys` (`audit_logs.actor`)** — FK covering index eklendi (`idx_audit_logs_actor`).
- **`unused_index` (INFO)** — Yanıltıcı: boş DB'de hiç sorgu çalışmadığı için. Indexler tasarımsal (senkron pull, audit sıralama, FK covering); **korunuyor**, aksiyon gerekmez. (Son taramada yalnızca `idx_audit_logs_created` raporlanıyor.)

### Ek sertleştirme — least-privilege (migration `0003_least_privilege_revoke`, 2026-06-06)
Sonradan fark edildi: Supabase'in `pg_default_acl`'i yeni public tablolara `anon`/`authenticated` için TAM privilege veriyordu (RLS bloklasa da derinlemesine savunma eksikti). Fazlalık privilege'lar revoke edildi; revoke sonrası security advisor yine **0 uyarı**. Son privilege matrisi: bkz. [PROJECT_INFO.md](../PROJECT_INFO.md) → Privilege modeli.

> **Not:** `auth_rls_initplan`, on dört turluk teorik review'ın kaçırdığı, yalnızca gerçek linter'ın yakaladığı bir bulguydu — gerçek çalıştırmanın değerini gösterir.

### Fresh-deploy + idempotentlik doğrulaması (lokal Supabase CLI, 2026-06-06)
Migration zinciri **sıfırdan bir lokal Postgres'te** (`supabase start`) uygulandı: üç migration da
hatasız geçti. Bu fresh DB'de aşağıdaki davranış testlerinin TAMAMI çalıştırıldı ve geçti; ayrıca
betik **iki kez** koşturuldu → ikinci koşuda da TEST 3 `count=1` (sabit token id'leri sayesinde
idempotent). Bu, dış review'ın iki bulgusunu kapattı:
> - **(yüksek)** `idx_audit_logs_actor` iki migration'da çift oluşturuluyordu → fresh deploy'da
>   "already exists" verirdi. `initplan` dosyasından kaldırıldı; fresh deploy artık hatasız (kanıtlandı).
> - **(düşük)** Test betiği "idempotent" diyordu ama token insert'lerinde sabit `id` yoktu. Sabit
>   id'ler eklendi; iki kez çalıştırılarak idempotentlik fiilen doğrulandı.

---

## Uçtan uca davranış testleri

Test kurulumu: 2 test kullanıcısı — biri `admin_users`'ta (admin), biri normal (kontrol grubu). RLS davranışı `set local role authenticated` + `request.jwt.claims` ile gerçek kullanıcı bağlamı simüle edilerek test edildi.

| # | Test | Beklenen | Gözlenen | Durum |
|---|---|---|---|---|
| 1a | Hook — admin kullanıcı | `app_metadata = {admin: true}` | `{admin: true}` | ✅ |
| 1b | Hook — normal kullanıcı | `app_metadata = {admin: false}` | `{admin: false}` | ✅ |
| 2 | `is_admin()` admin claim ile | `true` | `true` | ✅ |
| 3 | Cross-user RLS izolasyonu | Kullanıcı 2 yalnız kendi token'ı (1); diğerini görmez | `visible=1, can_see_other=false` | ✅ |
| 4 | `with check` — başkası adına insert | Reddedilir; user1 token sayısı 1'de kalır | insert engellendi, sayı=1 | ✅ |
| 5a | `audit_logs` — admin okur | Görür (1) | 1 | ✅ |
| 5b | `audit_logs` — non-admin | Görmez (0) | 0 | ✅ |
| 6 | FK cascade + temizlik | Kullanıcı silinince token+admin cascade; hepsi 0 | hepsi 0 | ✅ |

---

## En kritik doğrulama

**`supabase_auth_admin` SELECT policy'si gerçekten gerekliydi ve çalışıyor.**
On dört tur boyunca teorik olarak tartışılan risk: "hook RLS'li `admin_users`'ı okuyamazsa claim **hep false** kalır." Gerçek test (1a/1b) hook'un `true`/`false`'u **doğru** ürettiğini kanıtladı → policy doğru kurulmuş.

**E2E izolasyonu kanıtlandı.** Test 3: bir kullanıcı başka kullanıcının (şifreli) token satırını veritabanı seviyesinde dahi göremiyor. Test 4: başkası adına yazamıyor.

---

## Tekrar çalıştırma

```bash
# psql ile
psql "$DATABASE_URL" -f supabase/tests/security_rls_tests.sql

# veya Supabase MCP execute_sql ile blok blok
```
Betik idempotent; kendi test verisini oluşturur ve sonunda temizler (sabit test UUID'leri, üretim verisine dokunmaz).

## Uçtan uca hook doğrulaması — GERÇEK login akışı (lokal CLI, 2026-06-06)
Önceki testler hook *fonksiyonunu* doğrudan çağırıyordu. `config.toml`'da
`[auth.hook.custom_access_token]` etkinleştirilip lokal stack (GoTrue dahil) başlatıldı ve
**tam auth pipeline** test edildi:
- signup → `admin_users`'a ekle → **gerçek `signin` (password grant)** → dönen JWT decode:
  `app_metadata.admin = true` ✅
- normal kullanıcı (admin değil) → JWT `app_metadata.admin = false` ✅ (negatif kontrol)
- Test kullanıcıları sonda silindi (kalıntı 0).

Bu, hook'un yalnız fonksiyon mantığında değil, **gerçek login sonrası token üretiminde** de
çalıştığını kanıtlar. (Canlı projede hook Dashboard'dan etkin; lokalde `config.toml` ile.)

## Bu raporun KAPSAMADIĞI (ileride eklenecek)
- Realtime publication davranışı (abone-önce bootstrap, arrival-order LWW) — gerçek client gerektirir.
- Yeni secret key `apikey` header / `verify_jwt=false` (Edge Function) — backend kurulunca.
- `private.admin_global_stats()` doğrudan-bağlantı + DB rolü grant testi — backend rolü kurulunca.
