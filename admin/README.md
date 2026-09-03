# admin — Yönetim Paneli (Next.js)

Faz 6. `project_auth` için uçtan uca şifreli TOTP uygulamasının yönetim paneli.
Bağımsız bir npm paketi: Flutter `analyze`/`test` akışına dahil **değil**, kendi
lockfile'ı ve kendi CI adımları var.

> **E2E sınırı (değişmez):** Panel hiçbir TOTP sırrını çözemez. `tokens.ciphertext`
> ve `key_attributes` satırları **hiçbir yoldan okunmaz**; yalnızca üst veri ve
> toplam sayımlar görünür.

---

## 1. Kurulum

```bash
cd admin
cp .env.example .env.local   # .env.local git-ignore'lu
npm ci
npm run dev
```

Node 22+ gerekir (`engines.node: >=22`).

### Ortam değişkenleri

| Değişken | Nerede | Açıklama |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | sunucu (ön ek gereği herkese açık) | Proje API URL'i |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | sunucu (ön ek gereği herkese açık) | `sb_publishable_…` — düşük yetkili, RLS'e tabi |
| `SUPABASE_SECRET_KEY` | **yalnız sunucu** | `sb_secret_…` — RLS bypass; asla tarayıcıya gitmez |
| `DATABASE_URL` | **yalnız sunucu** | `admin_app` login rolü ile Postgres bağlantısı |
| `SUPABASE_CA_CERT` | **yalnız sunucu** | Postgres CA sertifikası (PEM). Şemada **opsiyonel**, pratikte (a) yolu için **zorunlu** — §5 madde 5. **Sertifika repoda hazır:** `admin/certs/supabase-prod-ca-2021.crt` (yükleme tek satırı `admin/certs/README.txt` içinde) |

> **`NEXT_PUBLIC_` ön eki hakkında:** bugün panelde **tarayıcı tarafı Supabase
> istemcisi yoktur** (giriş/çıkış ve tüm okumalar sunucu bileşenleri ve server
> action'lar üzerinden gider), bu yüzden bu iki değer pratikte yalnızca sunucuda
> okunur ve istemci paketine hiç girmez. Ön ek yine de korunuyor: değerler tanımı
> gereği herkese açıktır ve ileride bir istemci bileşeni gerekirse yeniden
> adlandırma gerekmez. Zararsız ama yanıltıcı olabilir — bu yüzden yazıyoruz.

Şema doğrulaması ikiye ayrılmıştır: herkese açık yarısı `src/lib/env.ts`,
sunucuya özel yarısı `src/lib/env.server.ts` (`import 'server-only'`). İkisi de
**eski `eyJ…` JWT anahtarlarını reddeder** (prefix zorunlu). Doğrulama
**tembeldir** (istek anında), bu yüzden `next build` gerçek sırlar olmadan da
çalışır.

### Postgres CA sertifikası (`SUPABASE_CA_CERT`)

Sertifika **repoda gömülüdür** — Supabase Root 2021 CA herkese açık bir kök
sertifikadır, sır değildir:

```bash
# proje kökünden
export SUPABASE_CA_CERT="$(cat admin/certs/supabase-prod-ca-2021.crt)"
# ya da .env.local'e tek satır olarak: bkz. admin/certs/README.txt
```

`admin/certs/README.txt` kaynak URL'i, SHA-256 parmak izini ve yükleme tek
satırını taşır. **Doğrulandı (2026-09-02):**
`openssl s_client -connect aws-1-eu-central-1.pooler.supabase.com:5432 -starttls postgres -CAfile admin/certs/supabase-prod-ca-2021.crt`
→ `Verify return code: 0 (ok)`. Ayrıntı ve zincir dökümü: §5 madde 5.

*Alternatif (aynı dosya, elle indirme):* Dashboard → Database → SSL Configuration.
Parmak izi eşleşmiyorsa dosyayı kullanmayın.

### Operatör adımı — `admin_app` login rolünün parolası (bir kez, Dashboard SQL Editor'da) — ✅ YAPILDI (2026-09-02)

> ✅ **Durum (2026-09-02):** migration **canlı projeye uygulandı** (`authenticator-dev`, DB sürümü
> `20260902201638`) ve **iki rol de mevcut**: `admin_backend` (NOLOGIN, NOINHERIT; `private` USAGE +
> `admin_global_stats()` EXECUTE, hiçbir tablo yetkisi yok) ve `admin_app` (LOGIN, `admin_backend` üyesi,
> `bypassrls`/`superuser`/`createrole` yok). Her iki rol için `public.tokens` ve `public.key_attributes`
> üzerinde `select` yetkisi **false** olarak ölçüldü.
>
> ✅ **`admin_app` parolası 2026-09-02'de operatör tarafından atandı** ve rol `DATABASE_URL` içine kondu.
> (a) yolu aynı gün uçtan uca denendi: pooler üzerinden hem 6543 hem 5432'de doğrulanmış TLS ile bağlanıldı,
> `set local role admin_backend` içinde `private.admin_global_stats()` sayımları döndürdü,
> `select count(*) from public.tokens` ise `42501 permission denied` ile reddedildi. **Öneri:** parola bir
> sohbet kanalından geçtiği için **rotasyon** önerilir — `alter role admin_app password '<yeni-parola>';` +
> `DATABASE_URL` güncellemesi.
>
> ⏳ **Geriye kalan operatör işleri:** (1) `sb_secret_…` anahtarı `admin/.env.local`'e yapıştırılmalı —
> **bu anahtar olmadan giriş yapılabilir ama panele girilemez**, çünkü `requireAdmin()`'in `admin_users`
> tazelik araması secret-key istemcisini kullanır (ayrıntı aşağıda); (2) `public.admin_users` içinde en az
> bir satır olmalı — bugün **yok** (`auth.users` yalnızca bir UI-test hesabı içeriyor), yoksa kimse
> `/login`'i geçemez.
>
> 📋 **Tek kanonik bekleyen-adım listesi** (nerede, nasıl, neyi açar):
> [supabase/PROJECT_INFO.md → Bekleyen operatör adımları](../supabase/PROJECT_INFO.md#bekleyen-operatör-adımları-operator-todo).
> Bu dosyada ikinci bir liste tutulmaz.

`supabase/migrations/20260902201638_admin_backend_role.sql` migration'ı **yalnızca**
NOLOGIN yetki taşıyıcı rolü (`admin_backend`) oluşturur ve ona `private` şemasında
`usage` + `private.admin_global_stats()` üzerinde `execute` verir (Desen B —
init migration'daki yorum bloğu). Login rolü ve parolası **migration'a/transcript'e
yazılmaz**; parolayı operatör elle atar. Bu projede adım **2026-09-02'de tamamlandı**; aşağıdaki SQL temiz
bir projede (ya da rotasyonda) aynen kullanılır:

```sql
-- Dashboard > SQL Editor (parolayı güvenli bir üreticiden alın, hiçbir yere yapıştırmayın)
alter role admin_app password '<güçlü-parola>';   -- rotasyon da aynı komut

-- Rol yoksa (temiz proje) önce:
--   create role admin_app login password '<güçlü-parola>';
--   grant admin_backend to admin_app;
```

Sonra `DATABASE_URL` bu rolle kurulur. **Panel asla `postgres` süper kullanıcısı
ile bağlanmaz.** Bağlantıda `set local role admin_backend` yapılır (aşağıda).

---


> **Canlı doğrulama (2026-09-02):** `admin_app` ile `aws-1-eu-central-1.pooler.supabase.com` üzerinden hem 6543 (transaction) hem 5432 (session) modunda bağlanıldı; `set local role admin_backend` içinde `private.admin_global_stats()` sayımları döndürdü, `select count(*) from public.tokens` ise `42501 permission denied` ile reddedildi. Bu projenin pooler hostu `aws-0-…` DEĞİL `aws-1-…`; `aws-0` hostu "tenant/user not found" döndürür.

## 2. Üç erişim yolu (ARCHITECTURE §6) ve karşılıkları

Yollar **asla karıştırılmaz**.

| Yol | Kimlik | Ne için | Modül |
|---|---|---|---|
| **(a)** Doğrudan Postgres | `DATABASE_URL` → `admin_app`, sonra `set local role admin_backend` | Yalnızca `select private.admin_global_stats()` — kullanıcılar arası **toplam** okuma | `src/lib/db.ts` (`getGlobalStats`) |
| **(b)** Secret key | `SUPABASE_SECRET_KEY` (`sb_secret_…`) | `auth.admin.*` (listUsers / ban / delete) + `announcements`/`catalog_services`/`feature_flags`/`audit_logs` yazma | `src/lib/supabase/admin.ts` (`createAdminClient`), `src/lib/audit.ts` (`writeAudit`) |
| **(c)** Kullanıcı oturumu | publishable key + `@supabase/ssr` çerezleri | Giriş/çıkış, admin-public tabloları okuma, `audit_logs` okuma (RLS `is_admin()`) | `src/lib/supabase/server.ts`, `src/proxy.ts` |

**(c) yolu bugün tamamen sunucu tarafıdır.** Giriş, çıkış ve tüm okumalar sunucu
bileşenleri / server action'lar üzerinden çerezli `createServerClient()` ile
yapılır. `src/lib/supabase/browser.ts` hiçbir yerden import edilmiyordu; ölü kod
olarak **silindi** (bir istemci bileşeni gerçekten gerekirse `createBrowserClient`
ile bilinçli olarak geri eklenir).

`private` şeması Data API'ye **exposed değildir**, bu yüzden (a) yolu `.rpc()` ile
çağrılamaz — doğrudan Postgres bağlantısı zorunludur.

### Yetkilendirme

- `src/proxy.ts` (Next.js 16'da `middleware.ts`'in yerini alan dosya) her istekte
  oturum çerezini tazeler; oturumsuz → `/login`, admin olmayan → `/forbidden`.
- **Proxy tek başına yeterli değildir.** Server Action'lar sayfa route'una POST
  olarak gider ve matcher değişikliği kapsamı sessizce daraltabilir; bu yüzden her
  ayrıcalıklı işlem kendi handler'ında `requireAdmin()` çağırır.
- `requireAdmin()` iddiaları `auth.getClaims()` ile **JWKS imza doğrulaması**
  yaparak okur ve `app_metadata.admin === true` şartını arar. Bu claim'i
  `public.custom_access_token_hook` üretir (`public.admin_users` tablosundan).
- **Tazelik kontrolü (fail-closed).** Claim token üretilirken damgalanır, yani
  `public.admin_users`'tan satırı silmek **mevcut access token'ı geçersizleştirmez**.
  Bu yüzden `requireAdmin()` claim'i doğruladıktan sonra secret-key istemcisiyle
  `admin_users` üzerinde **bir PK araması** daha yapar; satır yoksa **veya okuma
  hata verirse** `ForbiddenError` fırlatır. Maliyet: her panel isteği başına bir
  indeksli arama (layout + sayfa + eylem hepsi `requireAdmin()` çağırır). Bunun
  bilinçli takası §6 madde 12'de; yetki geri alma adımları §9'da.

---

## 3. Modül sözleşmesi

```ts
// src/lib/env.ts                (istemci + sunucu; tembel doğrulama)
export const publicEnvSchema: ZodObject
export type PublicEnv
export function getPublicEnv(): PublicEnv

// src/lib/env.server.ts         ('server-only'; tembel doğrulama)
export const serverEnvSchema: ZodObject             // + SUPABASE_CA_CERT (opsiyonel, PEM)
export type ServerEnv
export function normaliseCaCert(value): string | undefined   // literal \n → gerçek satır sonu
export function getServerEnv(): ServerEnv           // window varsa ayrıca fırlatır

// src/lib/supabase/server.ts    (sunucu; çerez tabanlı oturum)
export async function createClient(): Promise<SupabaseClient>

// src/lib/supabase/admin.ts     ('server-only'; secret key)
export function createAdminClient(): SupabaseClient

// src/lib/db.ts                 ('server-only'; doğrudan Postgres)
export const globalStatsSchema: ZodObject
export type GlobalStats = { total_users: number; total_tokens: number;
                            total_devices: number; generated_at: string }
export function parseGlobalStats(value: unknown): GlobalStats
export function buildSslOptions(ca): { rejectUnauthorized: true; ca?: string }  // saf, testli
export async function getGlobalStats(): Promise<GlobalStats>

// src/lib/forbidden.ts          (saf; import'u YOK — istemci bileşeni de kullanabilir)
export const FORBIDDEN_DIGEST = 'ADMIN_FORBIDDEN'
export const ADMIN_REVOKED_MESSAGE: string
export class ForbiddenError extends Error            // name + digest sabit

// src/lib/auth.ts               (sunucu; forbidden.ts'i yeniden dışa aktarır)
export interface AdminIdentity { userId: string; email: string | null }
export function isAdminClaims(claims: unknown): boolean
export async function requireAdmin(): Promise<AdminIdentity>  // claim + admin_users tazeliği

// src/lib/audit.ts              ('server-only')
export const AUDIT_ACTIONS: readonly AuditAction[]
export type AuditAction =
  | 'user.ban' | 'user.unban' | 'user.delete'
  | 'announcement.create' | 'announcement.update' | 'announcement.delete'
  | 'catalog.create' | 'catalog.update' | 'catalog.delete'
  | 'flag.update'
export interface AuditEntry { actor: string; action: AuditAction; target?: string | null }
export async function writeAudit(entry: AuditEntry): Promise<void>

// src/lib/nav.ts                (saf veri)
export interface NavItem { href: string; label: string }
export const NAV_ITEMS: readonly NavItem[]

// src/lib/stats.ts              ('server-only'; (a) yolunun panel sarmalayıcısı)
export type GlobalStatsResult = { ok: true; stats: GlobalStats } | { ok: false; message: string }
export async function loadGlobalStats(): Promise<GlobalStatsResult>   // asla fırlatmaz

// src/lib/users.ts              (saf; SDK/`server-only` importu YOK — bu yüzden birim testli)
export const BAN_DURATION_FOREVER = '876600h'
export const BAN_DURATION_NONE = 'none'
export const USERS_PER_PAGE = 50
export interface AdminUserRow, UsersPage, RawAuthUser, RawListUsersResponse
export function deriveStatus(bannedUntil, now?): { status: UserStatus; bannedUntil: string | null }
export function deriveProviders(appMetadata): string[]
export function mapUserRow(user, options): AdminUserRow
export function buildUsersPage(response, page, options): UsersPage
export function filterRowsByEmail(rows, query): AdminUserRow[]      // SAYFA-YEREL (invariant lowercase)
export function parsePageParam(raw): number
export function checkUserActionAllowed(input): ActionVerdict        // kendine + diğer admin'e hayır
export function describeActionError(intent, error): string
export function summariseError(error): string                       // sır/DSN redaksiyonlu
export function formatDateTime(value): string
export function shortId(value): string

// src/app/(dashboard)/users/data.ts   ('server-only'; (b) yolu)
export async function fetchAdminUserIds(): Promise<Set<string>>     // okunamazsa FIRLATIR (fail-closed)
export async function loadUsersPage(page, actorId): Promise<UsersPageResult>

// src/lib/announcements.ts      (saf; I/O yok)
export const ANNOUNCEMENT_AUDIENCES = ['all','flutter','android','ios'] as const
export const TITLE_MAX_LENGTH = 120, BODY_MAX_LENGTH = 4000
export const announcementInputSchema: ZodObject
export function mapAnnouncementRow(row): Announcement | null        // bozuk satır karantinaya
export function mapAnnouncementRows(rows): Announcement[]
export function formatDateTime(iso): string                         // deterministik UTC

// src/lib/catalog.ts            (saf; I/O yok)
export const NAME_MAX_LENGTH = 80, ISSUER_MAX_LENGTH = 80, LOGO_URL_MAX_LENGTH = 512
export function isHttpsUrl(value): boolean                          // yalnız mutlak https://
export const catalogInputSchema: ZodObject
export function mapCatalogRow(row): CatalogService | null

// src/lib/flags.ts              (saf; I/O yok)
export const TOKEN_SYNC_FLAG_KEY = 'token_sync_enabled'
export const TOKEN_SYNC_WARNING: string
export const FLAG_KEY_PATTERN: RegExp, PAYLOAD_MAX_BYTES = 8 * 1024
export const FORBIDDEN_PAYLOAD_KEYS = ['__proto__','constructor','prototype']
export const PAYLOAD_UNUSABLE_WARNING: string
export function parseFlagPayload(raw): FlagPayloadResult            // JSON nesnesi ya da null
export const flagCreateSchema, flagPayloadUpdateSchema, flagToggleSchema, flagDeleteSchema
export function mapFlagRow(row): FeatureFlag | null                 // + payloadUnusable: boolean
export function formatPayload(payload): string
export function flagAuditTarget(key, operation): string             // 'token_sync_enabled:disable'

// src/lib/paging.ts             (saf; her sayfalı tablonun ortak aritmetiği)
export const DEFAULT_PAGE_SIZE = 50, MAX_PAGE = 10_000
export type SearchParamValue = string | string[] | undefined
export function firstSearchParamValue(value): string | undefined
export function parsePage(value, maxPage?): number                  // [1, maxPage]'e kırpar
export function pageRange(page, pageSize?): { from: number; to: number }   // .range() sınırları
export function pageCount(total, pageSize?): number                 // her zaman >= 1
export function hasNextPage(page, total, rowCount, pageSize?, maxPage?): boolean
export function pageHref(basePath, page): string                    // sayfa 1 sorgusuz

// src/lib/audit-query.ts        (saf; /audit'e özgü arama parametreleri — paging.ts üzerine kurulu)
export const AUDIT_PAGE_SIZE = 50, AUDIT_SEARCH_MAX_LENGTH = 100, AUDIT_MAX_PAGE = 10_000
export function parseAuditQuery(params): AuditQuery                 // action beyaz listeli
export function auditRange(page, pageSize?): { from: number; to: number }
export function auditPageCount(total, pageSize?): number
export function auditHasNextPage(page, total, rowCount, pageSize?): boolean
export function escapeLikePattern(value): string                    // %/_ kaçışlı, * düşürülür
export function buildAuditHref(query): string
export function auditActionLabel(action): string
export function auditActionVariant(action): 'secondary' | 'destructive' | 'outline'
```

Yeni sayfa eklemek: `src/app/(dashboard)/<route>/page.tsx` + `NAV_ITEMS`'a bir satır.
`(dashboard)` layout'u zaten `requireAdmin()` çağırır ve `force-dynamic`'tir.

### Rotalar

| Rota | Dosya | Koruma | Erişim yolu | `audit_logs` |
|---|---|---|---|---|
| `/login` | `src/app/login/page.tsx` + `login/actions.ts` | genel (proxy `PUBLIC_PATHS`) | (c) | — |
| `/forbidden` | `src/app/forbidden/page.tsx` | genel | — | — |
| `/` | `src/app/(dashboard)/page.tsx` | proxy + layout + `requireAdmin()` | (a) sayımlar, (c) son 10 kayıt | — |
| `/users` | `(dashboard)/users/page.tsx` + `data.ts` + `actions.ts` | proxy + layout + eylemde `requireAdmin()` | (b) | `user.ban` / `user.unban` / `user.delete` |
| `/announcements` | `(dashboard)/announcements/page.tsx` + `actions.ts` | aynı | okuma (c), yazma (b) | `announcement.create` / `.update` / `.delete` |
| `/catalog` | `(dashboard)/catalog/page.tsx` + `actions.ts` | aynı | okuma (c), yazma (b) | `catalog.create` / `.update` / `.delete` |
| `/flags` | `(dashboard)/flags/page.tsx` + `actions.ts` | aynı | okuma (c), yazma (b) | `flag.update` (`target` = `<key>:create\|enable\|disable\|payload\|delete`) |
| `/audit` | `(dashboard)/audit/page.tsx` | proxy + layout + `requireAdmin()` | (c), RLS `is_admin()` | — (yalnız okur) |
| `/auth` (sayfa değil) | `src/app/auth/actions.ts` | genel yol öneki; `signOut` + `/login` yönlendirmesi | (c) | — |

`(dashboard)` grubunun bir **error boundary**'si vardır:
`src/app/(dashboard)/error.tsx`. `requireAdmin()` yönlendirme yerine
`ForbiddenError` fırlattığı için (proxy'nin çalışmadığı bir dağıtımda ya da bir
matcher değişikliğinden sonra buraya düşülebilir) boundary olmadan ham Next.js
hata ekranı görünürdü. Boundary hatayı **`digest`** ile tanır: üretim derlemesinde
Next mesajı ve stack'i siler ama hatanın **zaten taşıdığı** digest'i korur
(`next/dist/server/app-render/create-error-handler.js:79-91`). Hata nesnesinden
hiçbir şey ekrana basılmaz — `message` sürücü/kısıt ayrıntısı taşıyabilir.

**Sayfalama.** `/users` dışındaki her tablo `src/lib/paging.ts` üzerine kuruludur: `?page=`, 50 satır/sayfa,
`count: 'exact'` + `.range()`, ve ortak `src/components/table-pagination.tsx` altbilgisi. Her sıralama
**belirleyici bir eşitlik bozucu** taşır — yoksa aynı `created_at`/`name` değerini paylaşan satırlar iki
sayfada birden görünebilir ya da ikisinin arasına düşüp hiç görünmez:

| Rota | Sıralama | Süzgeç |
|---|---|---|
| `/audit` | `created_at desc, id desc` | `?action=` (beyaz listeli), `?q=` (`ilike`) |
| `/announcements` | `created_at desc, id desc` | — |
| `/catalog` | `name asc, id asc` | — |
| `/flags` | `key asc` (`key` birincil anahtar; eşitlik bozucu gerekmez) | — |

"Sonraki sayfa var mı" **ham satır sayısından** hesaplanır, eşlenmiş satırlardan değil: `mapAnnouncementRow` /
`mapCatalogRow` / `mapFlagRow` karantinaya aldığı bozuk bir satır da sayfada bir yer kaplar, eşlenmiş sayıya
bakmak tablonun kalanını tek bozuk satırın arkasına saklardı. Aralık dışı bir `?page=` (ör. elle yazılmış
`?page=99`) "Bu sayfada kayıt yok" + ilk sayfaya bağlantı gösterir — "tablo boş" metni orada yalan olurdu.

Server action'lar **taban yolu** revalidate etmeye devam eder (`revalidatePath('/catalog')`): Next oraya bir
URL değil bir *rota dosya yapısı* yolu ister, sorgu dizesi bunun parçası değildir — taban yol zaten her
`?page=` sayfasını kapsar, `'/catalog?page=2'` ise var olmayan bir rotayı adlandırıp hiçbir şeyi
tazelemezdi.

`/users` bu modülü **kullanmaz**: `auth.admin.listUsers` PostgREST `.range()`'i değil Auth admin API'sinin
`page`/`perPage`'ini kullanır, bu yüzden kendi yardımcıları `lib/users.ts` içinde kalır. `/users` araması da
**sayfa-yereldir**: `auth.admin.listUsers` yalnızca `page`/`perPage` alır, sunucu tarafı e-posta süzgeci
yoktur ve arayüz bunu açıkça yazar.

---

## 4. Komutlar

| Komut | Ne yapar |
|---|---|
| `npm run dev` | Geliştirme sunucusu |
| `npm run lint` | ESLint (flat config, `eslint-config-next`) |
| `npm run typecheck` | `tsc --noEmit` (üretilen `.next/types`'a bağımlı değil) |
| `npm run test` | Vitest (jsdom + Testing Library) |
| `npm run build` | `next build` — gerçek sır gerektirmez |

`npm run test` bugün **256 test / 14 dosya** çalıştırır ve hepsi saftır (ağ yok, gerçek Supabase istemcisi
yok — server action testleri istemciyi modül sınırında `vi.mock`'lar; `test/postgrest-mock.ts` postgrest-js
zincirinin sadece kullanılan kısmını taklit eder).
CI aynı sırayı `.github/workflows/admin-ci.yml` içinde koşar (`npm ci` → **audit** → lint → typecheck →
test → build), yalnızca `admin/**` değişikliklerinde tetiklenir ve **hiçbir Supabase sırrı verilmez** —
gerçek kimlik bilgisi istemeye başlayan bir build bu adımda düşer.

Denetim adımı `npm audit --omit=dev --audit-level=high`'dır ve **kapsamı bilinçlidir**: yalnızca çalışan
panelde gerçekten yer alan bağımlılıklar boruyu durdurabilir. Yalnız-geliştirme bir uyarı (eslint, vitest, bir
geçişli derleme aracı) gerçek bir iştir ama üretim maruziyeti değildir; onun boruyu düşürmesi herkesi bu adımı
görmezden gelmeye alıştırırdı — oysa adımın tek işi, bilinen açığı olan bir **çalışma zamanı** bağımlılığını
durdurmaktır. `--audit-level=high` aynı nedenle: high + critical düşürür, low/moderate yalnızca raporlanır.
Bağımlılıklar tam sürüme sabitli ve `package-lock.json` commit'li olduğu için denetlenen ağaç, `npm ci`'nin
az önce kurduğu ağacın tam olarak kendisidir. Bugün (2026-09-03) sonuç: **0 açık** (geliştirme bağımlılıkları
dahil edildiğinde de 0).

---

## 5. Doğrulanan dokümanlar (2026-09-02)

Kütüphane API'leri hafızadan değil, güncel dokümandan ve **kurulu paketin
kaynağından** doğrulandı.

1. **`@supabase/ssr` + Next.js 16 proxy/çerez** —
   <https://nextjs.org/docs/app/api-reference/file-conventions/proxy> (sayfa
   `version: 16.3.4`, `lastUpdated: 2026-08-25`): `middleware` dosya kuralı
   **deprecated**, adı `proxy` oldu (v16.0.0); dosya proje kökünde ya da `src/`
   içinde, dışa aktarılan fonksiyonun adı `proxy` (veya default export); Proxy
   varsayılan olarak **Node.js runtime**'ında çalışır. Çerez sözleşmesi
   `getAll`/`setAll(cookiesToSet, headers)` — ikinci parametre
   (`Cache-Control: private, no-cache, no-store…`) kurulu paketin tip
   tanımından doğrulandı: `node_modules/@supabase/ssr/dist/main/types.d.ts`
   (`SetAllCookies`). Supabase'in kendi Next.js örneği de artık `proxy.ts`
   kullanıyor (Context7 → `supabase/supabase`, `examples/prompts/nextjs-supabase-auth.md`).
   `next build` çıktısında satır `ƒ Proxy (Middleware)` olarak görünür.
2. **`getClaims()` vs `getUser()`** —
   <https://supabase.com/docs/guides/auth/server-side/nextjs.md> ve
   `node_modules/@supabase/auth-js/dist/module/GoTrueClient.d.ts`: sayfa/veri
   korumak için **`getClaims()`** önerilir; token'ı projenin JWKS ucuna
   (`/auth/v1/.well-known/jwks.json`) karşı **imza doğrulayarak** okur ve
   asimetrik anahtarlarda ağ isteği gerektirmez. Süresi dolmak üzere olan
   oturumu **önce yeniler**, bu yüzden proxy'de oturum tazeleme görevini de
   görür. Dönüş: `{ data: { claims, header, signature }, error: null }` |
   `{ data: null, error }`; `claims.app_metadata?: UserAppMetadata` (types.d.ts
   satır 1684) — `app_metadata.admin` buradan okunur. `getSession()`'ın user
   nesnesine güvenilmez (çerez paylaşımlı depolamadır).
3. **`sb_secret_…` anahtarı ve `createClient(url, key)`** —
   <https://supabase.com/docs/guides/api/api-keys.md>: yeni anahtarlar JWT
   **değildir**, `apikey` başlığıyla gönderilir, `Authorization: Bearer <secret>`
   kullanılmaz. Doküman `createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SECRET_KEY!)`
   biçimini açıkça gösteriyor. Kurulu `@supabase/supabase-js@2.114.0`
   (`dist/index.mjs`) bunu SDK içinde hallediyor: `isNewApiKey()` `sb_publishable_`/
   `sb_secret_` ön eklerini tanıyor, `apikey` başlığını **her zaman** set ediyor,
   ve platformun JWT olarak ayrıştırmaya çalıştığı yerde (Edge Functions)
   `omitApiKeyAsBearer: true` ile Bearer geri dönüşünü kapatıyor. Sonuç: elle
   başlık kurmaya gerek yok; `createAdminClient()` anahtarı doğrudan
   `createClient()`'a veriyor. Anahtar tarayıcıda çalışmaz (Supabase
   `User-Agent`'a bakıp 401 döner) — zaten `import 'server-only'` ile engelli.
4. **Pooler modu ve `SET LOCAL ROLE`** —
   <https://supabase.com/docs/guides/database/connecting-to-postgres.md>:
   Supavisor **transaction mode (port 6543)** serverless için önerilir ama
   **prepared statement desteklemez** ("turn off prepared statements for your
   connection library"); session mode (5432) ve doğrudan bağlantı destekler.
   `SET LOCAL ROLE` işlem kapsamlıdır, dolayısıyla açık bir transaction içinde
   her iki modda da güvenlidir (transaction mode oturum durumunu işlemler arası
   sıfırlar; `SET ROLE` — LOCAL'sız — orada güvenilmez). `src/lib/db.ts` bu
   yüzden `sql.begin()` içinde `set local role admin_backend` çalıştırır ve
   sürücüyü `prepare: false` ile kurar; böylece her iki port da çalışır.
   Sürücü olarak `postgres` (porsager) kullanılıyor (ARCHITECTURE §6 tercihi;
   dokümanda serverless için aksi bir öneri yok).

5. **Postgres TLS: `ssl: 'require'` doğrulama yapmaz; pooler sertifikası herkesçe
   güvenilen bir kökten gelmez** (inceleme bulgusu P2-3, doğrulama 2026-09-02).
   Kurulu `postgres@3.4.9` kaynağı (`src/connection.js:283`): `'require' | 'allow' |
   'prefer'` dizgelerinin **hepsi** `options.rejectUnauthorized = false` yapar — yani
   bağlantı şifreli ama **kimliği doğrulanmamış**tır (libpq `sslmode=require`
   semantiği). Hemen altındaki `else if (typeof ssl === 'object')
   Object.assign(options, ssl)` dalı desteklenen çıkış kapısıdır, `src/lib/db.ts`
   artık onu kullanır: `{ rejectUnauthorized: true, ...(ca ? { ca } : {}) }`.

   **`ca` pratikte zorunludur.** Supavisor pooler'ının sunduğu zincir canlı olarak
   ölçüldü (`openssl s_client -connect aws-1-eu-central-1.pooler.supabase.com:5432
   -starttls postgres`, 2026-09-02):

   ```
   0 s:CN=*.pooler.supabase.com          i:CN=Supabase Intermediate 2021 CA
   1 s:CN=Supabase Intermediate 2021 CA  i:CN=Supabase Root 2021 CA
   2 s:CN=Supabase Root 2021 CA          i:CN=Supabase Root 2021 CA   (kendinden imzalı)
   verify error:num=19:self-signed certificate in certificate chain
   ```

   Kök **Supabase'in kendi özel CA'sıdır**; hiçbir genel güven deposunda yoktur.
   Dolayısıyla `SUPABASE_CA_CERT` verilmezse `rejectUnauthorized: true` el sıkışması
   **kapalı düşer** (stats kartları hata kartı gösterir) — istenen davranış budur,
   sessiz doğrulamasız bağlantı değil. Şemada opsiyonel tutulmasının tek nedeni
   panelin (a) yolu olmadan da açılıp derlenebilmesidir.

   Doküman tarafı bunu **açıkça yazmıyor**, o yüzden ölçüm yapıldı:
   <https://supabase.com/docs/guides/platform/ssl-enforcement.md> yalnızca
   `verify-full` için Supabase CA sertifikasının indirilmesi gerektiğini ve
   sertifikanın Dashboard'da **SSL Configuration** bölümünde bulunduğunu söyler;
   <https://supabase.com/docs/guides/database/connecting-to-postgres.md> "mümkün
   olan her yerde SSL" der ve "Server root certificate"ın dashboard'dan alınacağını
   belirtir. İkisi de pooler zincirinin genel olarak güvenilir olup olmadığını
   söylemez.

   **Kapanış (2026-09-02): kök sertifika artık repoda.** `admin/certs/supabase-prod-ca-2021.crt`
   (+ `admin/certs/README.txt`) — Supabase Root 2021 CA, herkese açık bir kök
   sertifika, sır değil. Aynı gün doğrulandı:

   ```
   openssl s_client -connect aws-1-eu-central-1.pooler.supabase.com:5432 \
     -starttls postgres -CAfile admin/certs/supabase-prod-ca-2021.crt
   → Verify return code: 0 (ok)
   ```

   - SHA-256 parmak izi:
     `80:70:25:AD:50:D4:ED:21:9D:2C:9C:7D:29:9C:00:4F:82:4E:B0:0C:F7:F6:5A:FE:F6:07:D0:7B:72:E6:CA:FA`
   - Geçerlilik: **2021-04-28 → 2031-04-26**
   - Çalışan indirme adresi:
     <https://supabase-downloads.s3-ap-southeast-1.amazonaws.com/prod/ssl/prod-ca-2021.crt>
     (bazı dokümanlardaki `us-west-2` URL'i buraya **301** ile yönlenir; `curl -L`
     kullanılmazsa S3'ten XML hata gövdesi döner — sessizce bozuk bir "sertifika"
     dosyası elde edilir). Elle indirme alternatifi: Dashboard → Database → SSL
     Configuration. Her iki durumda da parmak izini yukarıdakiyle karşılaştırın.

   `.env` tek satır taşıyabildiği için PEM'deki literal `\n` dizileri
   `normaliseCaCert()` ile gerçek satır sonlarına çevrilir.

Ek: <https://supabase.com/changelog.md> taraması — `@supabase/ssr` `getAll`/`setAll`
çerez API'si (eski `get`/`set`/`remove` v1.0'da kaldırılacak), asimetrik JWT imza
anahtarları ve `getClaims()` duyurusu; ele alınan sürümleri bozacak yeni bir
kırılma bulunamadı.

---

## 6. Güvenlik değişmezleri

1. `SUPABASE_SECRET_KEY`, `DATABASE_URL` ve `SUPABASE_CA_CERT` **yalnızca
   sunucuda**. Bunları okuyan her modül `import 'server-only'` ile başlar —
   artık şemanın kendisi de: `lib/env.server.ts`, `lib/supabase/admin.ts`,
   `lib/db.ts`, `lib/audit.ts`. Marker'ı `getServerEnv()`'in `typeof window`
   kontrolünden **önce** koyduk: ilki derleme zamanı hatası, ikincisi çalışma
   zamanı. `NEXT_PUBLIC_` ön eki bu değerlere **asla** verilmez.
2. Panel `tokens` / `key_attributes` satırlarını **hiçbir yoldan okumaz**.
   Kullanıcılar arası tek okuma `private.admin_global_stats()` üzerinden gelen
   sayımlardır.
3. Panel Postgres'e **asla `postgres` rolüyle** bağlanmaz; `admin_app` →
   `set local role admin_backend`.
4. Her ayrıcalıklı işlem, işlemi yapan handler'ın içinde **bir `audit_logs`
   satırı** yazar (`writeAudit`). `actor` her zaman `requireAdmin()`'den gelir,
   asla istek gövdesinden. **Denetim yazımının başarısızlığı, işlemin
   başarısızlığından ayrı raporlanır:** o noktada işlem çoktan olmuştur, ikisini
   birleştirmek ya gerçekleşmiş bir değişikliği hatanın arkasına saklar ya da
   kaydı delik olan bir işlemi "başarılı" gösterir.
5. Yetki kontrolü çift katmanlıdır: `src/proxy.ts` + her handler'da
   `requireAdmin()`. Proxy'ye tek başına güvenilmez.
6. Giriş hatası mesajı, hesabın var olup olmadığını sızdırmaz. Yönetici olmayan
   oturum **anında `signOut()`** edilir ve "Bu hesap yönetici değil" gösterilir.
7. `.env.local` git-ignore'lu; `.env.example` yalnızca yer tutucu içerir.
8. Bağımlılıklar **tam sürüme sabitlenmiştir** (`^`/`~` yok) ve
   `package-lock.json` commit edilir.
9. `/users` üzerindeki yıkıcı işlemlerin muhafızları **sunucu tarafındadır ve
   kapalı düşer:** kendi hesabınıza ve başka bir yöneticiye işlem yapılamaz
   (`checkUserActionAllowed`), ve `public.admin_users` **okunamazsa**
   `fetchAdminUserIds()` fırlatır — boş kümeye düşseydi bir yöneticiyi yasaklamak
   sessizce serbest kalırdı. Yönetici yetkisi vermek/almak bilerek panelde yoktur;
   `public.admin_users` üzerinde SQL adımıdır.
10. **Silmenin FK cascade'i arayüzde yazar:** `auth.users` satırı silinince
   `tokens`/`key_attributes`/`devices` satırları da gider ve E2E gereği bunlar
   **geri getirilemez** — anahtar hiçbir zaman başkasında değildi.
11. `token_sync_enabled` **silinemez** (satır yoksa istemciler senkronu AÇIK
   varsayar; silmek kapatmanın tersidir) ve kapatmak onay ister.
   `catalog_services.logo_url` yalnız **mutlak `https://`** kabul eder: sütun
   herkese açık okunur, `javascript:`/`data:` bir değer ileride onu render eden
   herhangi bir istemci için depolanmış yük olurdu.
12. **Yönetici yetkisi geri alma anında etkilidir.** `requireAdmin()` claim'i
   doğruladıktan sonra `public.admin_users` üzerinde bir PK araması daha yapar ve
   satır yoksa **veya okuma hata verirse** reddeder. Takas bilinçlidir: her panel
   isteği başına bir indeksli arama daha; karşılığında "yetkiyi aldım, laptopu
   kapattım" ile gerçeğin arasında bir token ömrü boyunca (varsayılan 1 saat)
   `auth.admin.deleteUser` çağırabilen bir hesap kalmaz. Runbook: §9.
13. **Hiçbir satırı etkilemeyen bir yazma başarı sayılmaz.** PostgREST, hiçbir
   satırla eşleşmeyen `PATCH`/`DELETE` için `204 No Content` ve **hata yok** döner;
   bu yüzden her `update`/`delete` `.select('<pk>')` ile etkilenen satırları geri
   ister ve boş sonuç, `revalidatePath`'ten **ve** `writeAudit`'ten **önce** hataya
   çevrilir. Aksi hâlde denetim kaydı hiç olmamış işlemleri anlatırdı — bir
   sonradan-atfetme günlüğü için eksik kayıttan daha kötüsü uydurma kayıttır.
14. **`feature_flags.payload` yazarken körlemesine silme yok.** Sütun bir JSON
   nesnesi değilse (dizi/skaler — SQL'den ya da ileride başka bir servisten)
   `mapFlagRow` onu istemcideki gibi `null`'a indirger **ama** `payloadUnusable`
   bayrağını kaldırır; payload penceresi boş bir alan yerine uyarı gösterir ve
   admin alana dokunana kadar **Kaydet kapalıdır**. Yıkım ancak bilinçli olabilir.
15. **`parseFlagPayload` prototip biçimli anahtarları reddeder** (`__proto__`,
   `constructor`, `prototype`; her derinlikte). `JSON.parse` `__proto__`'yu **kendi
   (own)** numaralandırılabilir anahtar yapar ve `JSON.stringify` onu geri yazar,
   yani anahtar herkesin anonim okuduğu bir sütuna aynen inerdi. Bugün sunucu
   tarafında hiçbir yer bu nesneyi merge etmiyor ve Dart bağışık — bu sertleştirme,
   yaşayan bir açığın kapatılması değil.

---

## 7. Elle duman testi (manual smoke checklist)

Birim testler saf mantığı kapsar (**256 test / 14 dosya**, `npm run test`); aşağıdaki akışlar **kapsanmaz** —
henüz Playwright/e2e yoktur. Gerçek Supabase'e karşı, `admin_app` rolü ve `public.admin_users`'ta en az bir
satır varken bir kez geçilmesi beklenir.

**Giriş / yetki**
- [ ] Yönetici olmayan bir hesapla `/login` → "Bu hesap yönetici değil" + oturum **anında kapatılır**
      (çerezler temizlenir; geri tuşu panele düşürmez).
- [ ] Yanlış parola → "E-posta veya parola hatalı" (hesabın var olup olmadığı sızmaz).
- [ ] Yönetici hesabıyla giriş → `/`. Oturum açıkken `/login`'e gitmek `/`'ye yönlendirir.
- [ ] Oturumsuz olarak `/users` → `/login`. Yönetici olmayan oturumla `/users` → `/forbidden`.
- [ ] `/forbidden` üzerindeki "Çıkış yap" → `/login`.

**Sayfalar**
- [ ] `/` — `DATABASE_URL`/`admin_app` **yokken**: sayımlar yerine hata kartı, ama sayfanın geri kalanı ve son
      10 denetim kaydı çalışır. Rol kurulduktan sonra: üç sayım + `generated_at` görünür.
- [ ] `/users` — 50 satır/sayfa, `?page=` ileri/geri; arama kutusu **yalnızca ekrandaki sayfayı** süzer ve bunu
      söyler; kendi satırınızda ve diğer yönetici satırlarında işlem menüsü kapalı.
- [ ] `/announcements`, `/catalog`, `/flags`, `/audit` menüden açılır; boş tablo boş-durum metni gösterir.
- [ ] `/announcements`, `/catalog`, `/flags` — 50 satır/sayfa, `?page=` ileri/geri; `?page=99` gibi aralık dışı
      bir sayfa "Bu sayfada kayıt yok" + ilk sayfa bağlantısı gösterir (boş tablo metnini değil).
- [ ] 2. sayfadayken bir kayıt oluştur/güncelle/sil → liste tazelenir (taban yol revalidate'i sayfalı URL'de de
      çalışır) ve sayfada kalınır.

**İşlemler (her biri sonrasında `/audit`'te yeni satır aranır)**
- [ ] Ban → satır "Yasaklı" olur; ilgili kullanıcı uygulamada oturum açamaz. `/audit` → `user.ban`.
- [ ] Unban → satır "Etkin"e döner. `/audit` → `user.unban`.
- [ ] Delete → onay penceresi **FK cascade uyarısını** gösterir; onaydan sonra satır listeden gider.
      `/audit` → `user.delete`.
- [ ] Kendi hesabınızda ban/delete denemesi → sunucu reddeder (menü kapalı olsa bile eylem kapalı düşer).
- [ ] Duyuru oluştur/güncelle/sil (`audience` = `all` ile Flutter uygulamasında Ayarlar'da göründüğü doğrulanır)
      → `announcement.create` / `.update` / `.delete`.
- [ ] Katalog kaydı oluştur/güncelle/sil; `http://` bir `logo_url` **reddedilir** →
      `catalog.create` / `.update` / `.delete`.
- [ ] Bayrak oluştur (geçersiz anahtar ve 8 KiB üstü payload reddedilir) → `flag.update`, `target`
      `<key>:create`.
- [ ] `token_sync_enabled` **kapatma** → onay penceresi "tüm istemcilerde token senkronunu durdurur" uyarısını
      gösterir; onaydan sonra istemcide senkron durur. `/audit` → `flag.update`, `target`
      `token_sync_enabled:disable`. Geri açınca `…:enable`.
- [ ] `token_sync_enabled` **silme** denemesi → reddedilir (silmek senkronu açık bırakırdı).

**Denetim kaydı**
- [ ] `/audit` — eylem süzgeci yalnızca bilinen eylemleri kabul eder; `?action=` elle bozulursa süzgeç
      **uygulanmaz** (500 değil). `?q=%` gibi bir arama joker gibi davranmaz.
- [ ] Sayfalama: 50'den fazla satırla 2. sayfa farklı satırlar gösterir, hiçbir satır iki sayfada birden
      görünmez ve `/` üzerindeki "son 10" kartı en yeni satırlarla eşleşir.

**İnceleme takipleri (P2/P3) — elle doğrulanacak**
- [ ] İki sekmede aynı duyuru açıkken birinden sil, diğerinden sil → ikinci istek **"bulunamadı"** hatası
      verir ve `/audit`'te **ikinci bir `announcement.delete` satırı oluşmaz**.
- [ ] `admin_users`'tan kendi satırınızı silin (başka bir yönetici oturumundan) → **çıkış yapmadan**, ilk
      sayfa yenilemesinde panel `/forbidden`'a düşer; token'ın süresinin dolması beklenmez.
- [ ] `SUPABASE_CA_CERT` boşken `/` → stats kartı hata verir (`self-signed certificate in certificate
      chain`); sertifika verildikten sonra sayımlar gelir.
- [ ] SQL ile `update public.feature_flags set payload = '[1,2,3]'::jsonb where key = '<test_key>'` →
      `/flags` satırında "JSON nesnesi değil" rozeti, payload penceresinde uyarı, **Kaydet kapalı**;
      metin alanına dokununca açılır.

---

## 8. Dağıtım notları

**Server Action origin kontrolü.** Next.js, bir Server Function isteğinin `Origin`
başlığını `Host` ile karşılaştırır ve uyuşmazsa isteği reddeder — Server
Function'lar için yerleşik CSRF savunması budur. `Host`'u yeniden yazan bir ters
vekil/CDN arkasında **tüm eylemler** opak bir hatayla düşmeye başlar. İki
desteklenen çözüm:

1. Paneli `Host` korunacak şekilde sunun (nginx'te `proxy_set_header Host $host;`,
   platformun `X-Forwarded-Host`'u onurlandırması). `admin/next.config.ts` bugün
   **boştur** ve bunu varsayar.
2. Dağıtım alan adlarını açıkça listeleyin:

   ```ts
   // admin/next.config.ts
   const nextConfig: NextConfig = {
     experimental: { serverActions: { allowedOrigins: ['panel.example.com', '*.example.com'] } },
   }
   ```

Anahtar adı **kurulu Next 16.3.4'ün tip tanımından** doğrulandı
(`node_modules/next/dist/server/config-shared.d.ts`, `experimental.serverActions`
→ `allowedOrigins?: string[]`, "Allowed origins that can bypass Server Action's
CSRF check"). Alan adı henüz belli olmadığı için `next.config.ts` içinde yalnızca
yorum olarak duruyor.

**TLS.** `SUPABASE_CA_CERT` üretimde ayarlanmalıdır (§5 madde 5). Ayarlanmazsa
panel açılır ve çalışır ama `/` üzerindeki sayım kartları el sıkışma hatası
gösterir — kapalı düşer, sessizce doğrulamasız bağlanmaz. Sertifika repoda
hazırdır: `admin/certs/supabase-prod-ca-2021.crt`, SHA-256 parmak izi
`80:70:25:AD:50:D4:ED:21:9D:2C:9C:7D:29:9C:00:4F:82:4E:B0:0C:F7:F6:5A:FE:F6:07:D0:7B:72:E6:CA:FA`,
geçerlilik 2021-04-28 → 2031-04-26; pooler el sıkışması bu dosyayla 2026-09-02'de
`Verify return code: 0 (ok)` verdi. Yükleme tek satırı `admin/certs/README.txt`
içinde. **Sertifikanın 2031'de dolduğunu unutmayın** — yenilendiğinde dosya ve
parmak izi birlikte güncellenmelidir.

---

## 9. Runbook — yönetici yetkisini geri alma (demotion)

`app_metadata.admin` claim'i token **üretilirken** damgalanır; satırı silmek
mevcut access token'ı geçersizleştirmez. `requireAdmin()`'deki tazelik kontrolü
(§6 madde 12) paneli anında kapatır, ama kullanıcının Supabase oturumu hâlâ
canlıdır. Tam sıra:

```sql
-- 1) Yetkiyi kaldır (panelde bilerek yoktur; SQL Editor'da yapılır).
delete from public.admin_users where user_id = '<uuid>';
```

```bash
# 2) O kullanıcının tüm oturumlarını sonlandır (refresh token dahil).
#    admin.signOut(jwt, 'global') kullanıcının kendi JWT'sini ister; elde yoksa
#    doğrudan Admin API ile oturumları düşürün:
curl -X POST "https://<PROJECT_REF>.supabase.co/auth/v1/admin/users/<uuid>/logout" \
  -H "apikey: $SUPABASE_SECRET_KEY" -H "Authorization: Bearer $SUPABASE_SECRET_KEY"
```

3. Adım 1 tek başına paneli kapatmaya **yeter** (her istekte `admin_users`
   aranır). Adım 2, kullanıcının mobil uygulamadaki oturumunu da düşürmek ve
   claim'i taşıyan token'ın hiç kullanılmamasını sağlamak içindir.
4. Kalıcı önlem: proje JWT süresini (Dashboard → Authentication → Sessions →
   *Access token expiry*) makul tutun. Tazelik kontrolü olmasaydı bu süre, geri
   alınmış bir yöneticinin `auth.admin.deleteUser` çağırabildiği pencere olurdu.
5. `/audit`'te doğrulayın: adım 1'den sonra o kullanıcının aktör olduğu **yeni**
   satır oluşmamalı.

---

## 10. Bilinen sınırlar / takip işleri

Bilerek açık bırakılan, kaydedilmiş maddeler:

1. **Sayımlı sayfalamanın sorgu maliyeti (P3-7).** Sayfalı her tablo (`/audit`,
   `/announcements`, `/catalog`, `/flags`) her yüklemede `count: 'exact'` çalıştırır;
   `audit_logs` üzerindeki mevcut indeks yalnızca `(created_at)`
   (`20260606152227_init_authenticator.sql:231`) ve `ilike('target', '%…%')`
   indekssizdir. Bugünkü hacimde sorun değil. Büyürse:
   `create index on public.audit_logs (created_at desc, id desc);` ve
   `count: 'planned'` (ya da sayımı tamamen bırakıp `hasNextPage`'in
   "dolu sayfa" sezgisine geçmek — `total === null` yolu zaten yazılı ve testli).
2. **Bağımlılık denetimi yalnızca üretim ağacını kapsar (P3-8a, kapatıldı — kalan
   sınır kapsamdır).** `.github/workflows/admin-ci.yml` artık `npm ci`'den hemen
   sonra `npm audit --omit=dev --audit-level=high` koşuyor, yani bilinen açığı olan
   bir **çalışma zamanı** bağımlılığı sessizce giremez. Kapsanmayan iki şey var ve
   ikisi de bilinçli: **yalnız-geliştirme** uyarıları (eslint/vitest/derleme araçları)
   boruyu düşürmez — üretim maruziyeti değiller ve düşürselerdi adım gürültüye
   dönüşürdü — ve **low/moderate** dereceler yalnızca raporlanır. Gerçek bir
   geliştirme-zinciri açığı bu yüzden elle (`npm audit`, tam ağaç) yakalanmalıdır.
   `dependency-review-action` hâlâ yok: PR diff'i üzerinden çalışır ve ayrı bir izin
   ister, `npm audit` ise `npm ci`'nin az önce kurduğu ağacın tam kendisini denetler.
3. **`admin-ci.yml` zorunlu (required) kontrol yapılamaz (P3-8b).** Her iki tetik de
   `paths: ['admin/**', …]` taşıdığı için `admin/` dokunmayan PR'larda job hiç rapor
   etmez. Zorunlu kontrol yapmadan önce ya her zaman koşan bir eş job eklenmeli ya da
   `paths-ignore` ile ters çevrilmeli. Faz 7 branch protection'dan önce karar verilecek.
4. **`escapeLikePattern` `*` karakterini kaçırmaz, atar (P3-11).** PostgREST `*`'ı
   PostgreSQL görmeden `%`'e çevirdiği için kaçış işe yaramaz; bu yüzden düşürülür.
   Sonuç: `target` alanında literal `*` içeren bir denetim kaydı **aranamaz**.
   Pratikte zararsız (hedefler uuid / bayrak anahtarı / `key:operation`), ama
   bilinçli ve kayıtlı bir sınır. Doğrulanmamış varsayım: PostgREST'in *tırnaksız*
   filtre değerlerinde ters bölü işaretini olduğu gibi ilettiği — canlı bir sorguyla
   sınanmadı; yanlışsa `%`/`_` içeren bir arama sessizce hiçbir şey eşleştirmez
   (güvenlik sorunu değil, yalnızca daraltma).
5. **e2e/Playwright yok.** §7'deki duman testi elle koşulur.
