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
| `NEXT_PUBLIC_SUPABASE_URL` | istemci + sunucu | Proje API URL'i |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | istemci + sunucu | `sb_publishable_…` — düşük yetkili, RLS'e tabi |
| `SUPABASE_SECRET_KEY` | **yalnız sunucu** | `sb_secret_…` — RLS bypass; asla tarayıcıya gitmez |
| `DATABASE_URL` | **yalnız sunucu** | `admin_app` login rolü ile Postgres bağlantısı |

Şema doğrulaması `src/lib/env.ts` içinde zod ile yapılır ve **eski `eyJ…` JWT
anahtarlarını reddeder** (prefix zorunlu). Doğrulama **tembeldir** (istek anında),
bu yüzden `next build` gerçek sırlar olmadan da çalışır.

### Operatör adımı — `admin_app` login rolü (bir kez, Dashboard SQL Editor'da)

> ⏳ **Durum (2026-09-02):** bu migration repoda var ama **canlı projeye (`authenticator-dev`) HENÜZ
> UYGULANMADI**. Uygulanana ve `admin_app` rolü oluşturulana kadar `/` sayfasındaki sayım kartları hata
> kartı gösterir; panelin geri kalanı (secret key yolu) çalışır. Ayrıca `public.admin_users` içinde en az
> bir satır olmalıdır, yoksa kimse `/login`'i geçemez.

`supabase/migrations/20260902120000_admin_backend_role.sql` migration'ı **yalnızca**
NOLOGIN yetki taşıyıcı rolü (`admin_backend`) oluşturur ve ona `private` şemasında
`usage` + `private.admin_global_stats()` üzerinde `execute` verir (Desen B —
init migration'daki yorum bloğu). Login rolü ve parolası **migration'a/transcript'e
yazılmaz**; operatör elle oluşturur:

```sql
-- Dashboard > SQL Editor (parolayı güvenli bir üreticiden alın, hiçbir yere yapıştırmayın)
create role admin_app login password '<güçlü-parola>';
grant admin_backend to admin_app;
```

Sonra `DATABASE_URL` bu rolle kurulur. **Panel asla `postgres` süper kullanıcısı
ile bağlanmaz.** Bağlantıda `set local role admin_backend` yapılır (aşağıda).

---

## 2. Üç erişim yolu (ARCHITECTURE §6) ve karşılıkları

Yollar **asla karıştırılmaz**.

| Yol | Kimlik | Ne için | Modül |
|---|---|---|---|
| **(a)** Doğrudan Postgres | `DATABASE_URL` → `admin_app`, sonra `set local role admin_backend` | Yalnızca `select private.admin_global_stats()` — kullanıcılar arası **toplam** okuma | `src/lib/db.ts` (`getGlobalStats`) |
| **(b)** Secret key | `SUPABASE_SECRET_KEY` (`sb_secret_…`) | `auth.admin.*` (listUsers / ban / delete) + `announcements`/`catalog_services`/`feature_flags`/`audit_logs` yazma | `src/lib/supabase/admin.ts` (`createAdminClient`), `src/lib/audit.ts` (`writeAudit`) |
| **(c)** Kullanıcı oturumu | publishable key + `@supabase/ssr` çerezleri | Giriş/çıkış, admin-public tabloları okuma, `audit_logs` okuma (RLS `is_admin()`) | `src/lib/supabase/server.ts`, `src/lib/supabase/browser.ts`, `src/proxy.ts` |

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

---

## 3. Modül sözleşmesi

```ts
// src/lib/env.ts                (istemci + sunucu; tembel doğrulama)
export const publicEnvSchema: ZodObject
export const serverEnvSchema: ZodObject
export type PublicEnv, ServerEnv
export function getPublicEnv(): PublicEnv
export function getServerEnv(): ServerEnv          // window varsa fırlatır

// src/lib/supabase/browser.ts   (istemci)
export function createClient(): SupabaseClient

// src/lib/supabase/server.ts    (sunucu; çerez tabanlı oturum)
export async function createClient(): Promise<SupabaseClient>

// src/lib/supabase/admin.ts     ('server-only'; secret key)
export function createAdminClient(): SupabaseClient

// src/lib/db.ts                 ('server-only'; doğrudan Postgres)
export const globalStatsSchema: ZodObject
export type GlobalStats = { total_users: number; total_tokens: number;
                            total_devices: number; generated_at: string }
export function parseGlobalStats(value: unknown): GlobalStats
export async function getGlobalStats(): Promise<GlobalStats>

// src/lib/auth.ts               (sunucu)
export class ForbiddenError extends Error
export interface AdminIdentity { userId: string; email: string | null }
export function isAdminClaims(claims: unknown): boolean
export async function requireAdmin(): Promise<AdminIdentity>

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
export function parseFlagPayload(raw): FlagPayloadResult            // JSON nesnesi ya da null
export const flagCreateSchema, flagPayloadUpdateSchema, flagToggleSchema, flagDeleteSchema
export function mapFlagRow(row): FeatureFlag | null
export function formatPayload(payload): string
export function flagAuditTarget(key, operation): string             // 'token_sync_enabled:disable'

// src/lib/audit-query.ts        (saf; /audit arama parametreleri)
export const AUDIT_PAGE_SIZE = 50, AUDIT_SEARCH_MAX_LENGTH = 100
export function parseAuditQuery(params): AuditQuery                 // action beyaz listeli
export function auditRange(page, pageSize?): { from: number; to: number }
export function auditPageCount(total, pageSize?): number
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

`/users` sayfalıdır (`?page=`, 50 satır/sayfa) ve `/audit` de öyle (50 satır/sayfa, `?action=`/`?q=` süzgeçli).
`/announcements`, `/catalog` ve `/flags` **sayfalama yapmaz** — tabloyu bütün olarak çeker (bugünkü satır
sayılarında sorun değil; büyürlerse `.range()` gerekir). `/users` araması **sayfa-yereldir**:
`auth.admin.listUsers` yalnızca `page`/`perPage` alır, sunucu tarafı e-posta süzgeci yoktur ve arayüz bunu
açıkça yazar.

---

## 4. Komutlar

| Komut | Ne yapar |
|---|---|
| `npm run dev` | Geliştirme sunucusu |
| `npm run lint` | ESLint (flat config, `eslint-config-next`) |
| `npm run typecheck` | `tsc --noEmit` (üretilen `.next/types`'a bağımlı değil) |
| `npm run test` | Vitest (jsdom + Testing Library) |
| `npm run build` | `next build` — gerçek sır gerektirmez |

`npm run test` bugün **153 test / 10 dosya** çalıştırır ve hepsi saftır (ağ yok, Supabase istemcisi yok).
CI aynı sırayı `.github/workflows/admin-ci.yml` içinde koşar (`npm ci` → lint → typecheck → test → build),
yalnızca `admin/**` değişikliklerinde tetiklenir ve **hiçbir Supabase sırrı verilmez** — gerçek kimlik bilgisi
istemeye başlayan bir build bu adımda düşer.

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

Ek: <https://supabase.com/changelog.md> taraması — `@supabase/ssr` `getAll`/`setAll`
çerez API'si (eski `get`/`set`/`remove` v1.0'da kaldırılacak), asimetrik JWT imza
anahtarları ve `getClaims()` duyurusu; ele alınan sürümleri bozacak yeni bir
kırılma bulunamadı.

---

## 6. Güvenlik değişmezleri

1. `SUPABASE_SECRET_KEY` ve `DATABASE_URL` **yalnızca sunucuda**. Bunları okuyan
   her modül `import 'server-only'` ile başlar (`lib/supabase/admin.ts`,
   `lib/db.ts`, `lib/audit.ts`); `getServerEnv()` ayrıca `typeof window` kontrolü
   yapar. `NEXT_PUBLIC_` ön eki bu iki değere **asla** verilmez.
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

---

## 7. Elle duman testi (manual smoke checklist)

Birim testler saf mantığı kapsar (**153 test / 10 dosya**, `npm run test`); aşağıdaki akışlar **kapsanmaz** —
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
