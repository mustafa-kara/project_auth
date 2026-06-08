# Authenticator App — Mimari Dokümanı

> E2E şifreli, çoklu cihaz senkronize TOTP/HOTP authenticator (Ente Auth benzeri).
> Flutter (mobil) + Next.js (admin) + Supabase (backend).

---

## 1. Genel Bakış

| Karar | Seçim |
|---|---|
| Çekirdek ürün | TOTP/HOTP/Steam authenticator |
| Platformlar (Faz 1) | iOS + Android |
| State management | Bloc (karma: basit → Cubit, karmaşık/event-driven → Bloc) |
| Mimari | Feature-first + katmanlı (data/domain/presentation) |
| Routing | go_router |
| Backend | Supabase (Auth + Postgres + Realtime + RLS) |
| Şifreleme | **E2E** (Ente modeli) — sunucu açık secret'ı asla göremez |
| Crypto lib | libsodium — `sodium ^3.4.6` + `sodium_libs ^3.4.6+4` (Faz 2'de uygulandı; sodium 4.x Dart 3.11+ ister, proje 3.10.7 → 3.x bilinçli karar, bkz. not + docs/CRYPTO.md) — XChaCha20-Poly1305 IETF (`crypto_aead_xchacha20poly1305_ietf_*`) + Argon2id (detay §2.4) |
| Key & kurtarma | Rastgele master key; master parola → KDF → KEK ile sarmalanır; ayrıca recovery key ile sarmalanır (detay §2.2) |
| Senkron | Gerçek zamanlı çoklu cihaz (Supabase Realtime) |
| Login | Faz 3: email/parola · **Faz 4**: Google + Apple Sign-In (developer hesapları gerekir) |
| Admin panel | Next.js / React (cross-user okuma: server-side direct Postgres + private aggregate fn · API/yazma: secret key + `auth.admin` · admin-public tablolar client ile) |
| Push | FCM (**Faz 4** — APNs sertifikası + Apple hesabı gerekir) |

> **Doğrulanacak paket versiyonları** (developer hesapları/kuruluma başlarken `flutter pub` ve `npm` ile teyit et): `sodium`, `flutter_secure_storage`, `mobile_scanner`, `local_auth`, `supabase_flutter`, `go_router`, `flutter_bloc`. Aşağıdaki seçimler Ocak 2026 itibarıyla geçerli, ama kuruluma başlarken son sürümleri kontrol et.
>
> 🔐 **Kripto paket kararı (Faz 2'de uygulandı, teyitli):** `sodium: ^3.4.6` +
> `sodium_libs: ^3.4.6+4`. `sodium 4.x` Dart SDK `^3.11.0` ister; bu proje Dart
> `3.10.7` (Flutter 3.38.6 stable) → **4.x ÇÖZÜLEMEZ**. `sodium_libs` pub'da
> "discontinued" görünse de pre-built binary yükler, native-assets/experiment flag
> GEREKTİRMEZ; 3.x hattı stable Flutter'da çalışır (integration testleriyle kanıtlı).
> İleride Dart 3.11+'a yükselince 4.x native-assets'e geçiş ayrı küçük migration.
> XChaCha20-Poly1305 IETF + Argon2id algoritma kararı değişmez. README/PLAN ile hizalı.
> Detay: docs/CRYPTO.md.

---

## 2. Güvenlik Mimarisi (en kritik bölüm)

### 2.1 Tehdit modeli
- **Güvenmediğimiz taraf:** Supabase sunucusu / DB yöneticisi / saldırgan DB'yi okusa bile TOTP secret'larını çözememeli.
- **Güvendiğimiz taraf:** Kullanıcının cihazı (secure enclave/keystore) ve kullanıcının aklındaki master parola.
- **Sonuç:** Sunucuya giden her secret **client tarafında şifrelenmiş** olmalı. Sunucu sadece opak blob'lar görür.

### 2.2 Anahtar hiyerarşisi (Ente modeli)

```
Master Parola (kullanıcı belirler — login parolasından AYRI)
        │  Argon2id (salt, opsLimit, memLimit DB'de saklanır)
        ▼
   KEK (Key Encryption Key) ── cihazdan asla çıkmaz
        │
        ├─ encrypt ──► Master Key (rastgele üretilen, asıl veri anahtarı)
        │                   │
        │                   └─ Master Key, KEK ile sarmalanıp (encryptedMasterKey) sunucuda saklanır
        │
        └─ Recovery Key (rastgele 256-bit, kullanıcıya 24 kelime/hex olarak gösterilir)
                 │
                 └─ Master Key ayrıca Recovery Key ile de sarmalanır (recoveryEncryptedMasterKey)
                    → parola unutulursa recovery key ile master key geri açılır
```

**Akış:**
1. Kayıtta: rastgele `masterKey` üret. Kullanıcı master parola girer → Argon2id → `KEK`.
2. `masterKey`'i hem `KEK` ile hem `recoveryKey` ile ayrı ayrı şifrele → ikisini de sunucuda sakla.
3. Her TOTP secret'ı `masterKey`'den türetilen anahtarla (XChaCha20-Poly1305) şifrelenir → ciphertext + nonce sunucuya gider.
4. Parola değişimi: sadece `masterKey`'in KEK-sarmalaması yeniden yazılır; tüm secret'lar yeniden şifrelenmez. (Önemli avantaj.)
5. Parola unutuldu: recovery key ile `masterKey` açılır, yeni parola → yeni KEK → yeniden sarmala.

### 2.3 Cihazda saklama
> **Faz 2 Patch 5'te UYGULANDI** — bu bölümdeki hızlı-unlock planı birebir gerçekleşti
> (iOS `biometryCurrentSet`+Secure Enclave, Android `setUserAuthenticationRequired`/
> `strongBiometricOnly`, `local_auth` yalnız prompt değil—availability, gerçek geçit
> `flutter_secure_storage.read` OS access-control'ü). Detay + tehdit modeli: [docs/CRYPTO.md §11](docs/CRYPTO.md).

- `KEK` ve açık `masterKey` **diskte plaintext tutulmaz.**
- Oturum boyunca `masterKey` bellekte tutulur; uygulama arka plana/kilide geçince temizlenir.
- **Hızlı unlock mekanizması (netleştirme):** master key, OS keystore'da **access-control'lü** bir anahtar tarafından sarmalanmış saklanır:
  - iOS: Keychain item `kSecAttrAccessControl` + `.biometryCurrentSet` (Secure Enclave destekli).
  - Android: Keystore'da `setUserAuthenticationRequired(true)` ile anahtar; StrongBox varsa kullanılır.
  - Burada `local_auth` yalnızca UI prompt'u tetikler; **gerçek güvenlik OS keystore access-control'ündedir** (local_auth'un "başarılı" dönüşü tek başına anahtara erişim vermez — anahtarı keystore'un kendisi biyometrik arkasında tutar).
  - `flutter_secure_storage` bu sarmalı blob'u saklamak için kullanılır; access-control gereksinimleri platform kanalıyla ayarlanır (gerekirse ince bir native köprü).
- Biyometrik başarısız/yoksa fallback: kullanıcı master parola girer → KEK → master key.

### 2.4 Şifreleme primitifleri
| Amaç | Primitif |
|---|---|
| Parola → anahtar | Argon2id (`crypto_pwhash`, alg = `crypto_pwhash_ALG_ARGON2ID13`) |
| Secret/veri şifreleme | XChaCha20-Poly1305 IETF AEAD — `crypto_aead_xchacha20poly1305_ietf_encrypt/decrypt` |
| Anahtar sarmalama (key wrap) | Aynı AEAD ailesi: `crypto_aead_xchacha20poly1305_ietf_*` |
| Recovery key kodlama | BIP39 benzeri kelime listesi veya hex |

> **API netleştirmesi:** XChaCha20-Poly1305 için doğru libsodium ailesi `crypto_aead_xchacha20poly1305_ietf_*`'tır. `crypto_secretbox` **kullanılmaz** — o XSalsa20-Poly1305'tir (farklı construction). Tutarlılık için tüm şifreleme/sarmalama tek aile (XChaCha20-Poly1305 IETF) üzerinden yapılır; 192-bit nonce sayesinde rastgele nonce üretimi güvenlidir.

> **Kritik kural:** Hiçbir kriptografi rutini elle yazılmaz. Sadece libsodium çağrılır. Nonce'lar her şifrelemede `randombytes_buf` ile rastgele üretilir ve ciphertext ile saklanır.

---

## 3. Katman Mimarisi (MVVM + Clean)

```
Presentation (View)  ── Flutter widget'ları, sadece UI
        │  watch/read
Bloc/Cubit (ViewModel) ── durum + UI mantığı, UseCase çağırır
        │
Domain (UseCase + Repository interface + Entity) ── saf Dart, framework-bağımsız
        │
Data (Repository impl + DataSource + DTO) ── Supabase, secure storage, crypto
```

- **View** asla Repository/Supabase'i doğrudan çağırmaz; sadece Bloc/Cubit ile konuşur.
- **Bloc/Cubit** = MVVM'deki ViewModel. State immutable (Freezed/Equatable).
- **Domain** saf Dart, test edilebilir, hiçbir paket import etmez (crypto interface'i bile burada soyut).
- **Data** Supabase + secure storage + libsodium implementasyonları.
- Bağımlılık enjeksiyonu: `get_it` + `injectable` (veya elle composition root).

---

## 4. Proje Yapısı (feature-first)

```
lib/
├── main.dart
├── app/
│   ├── app.dart                 # MaterialApp.router
│   ├── router/                  # go_router config + guard'lar (auth/lock)
│   └── di/                      # get_it kayıtları
├── core/
│   ├── crypto/                  # CryptoService interface + libsodium impl
│   ├── storage/                 # SecureStorage wrapper
│   ├── error/                   # Failure/Exception tipleri
│   ├── network/                 # Supabase client wrapper
│   ├── theme/  · l10n/  · utils/
├── features/
│   ├── auth/                    # kayıt, giriş, master parola, recovery
│   │   ├── data/ · domain/ · presentation/
│   ├── vault/                   # TOTP listesi, ekleme, kod üretimi
│   │   ├── data/   (TokenRepository, SyncDataSource)
│   │   ├── domain/ (Token entity, GenerateCode, AddToken, SyncTokens)
│   │   └── presentation/ (VaultBloc, kod kartları, arama, klasör)
│   ├── scanner/                 # QR tarama + manuel giriş
│   ├── import_export/           # Google Auth / Aegis / 2FAS
│   ├── lock/                    # biyometrik/PIN uygulama kilidi
│   └── settings/                # tema, dil, hesap, parola değiştir
└── shared/                      # ortak widget'lar
```

`otp/` çekirdek (TOTP/HOTP/Steam algoritmaları) ayrı bir `core/otp/` modülü olarak izole edilir ve birim testlerle RFC 6238/4226 test vektörlerine karşı doğrulanır.

---

## 5. Supabase Veri Modeli & RLS

### Tablolar
```sql
-- Kullanıcı kripto metadatası (sunucu hiçbir açık anahtar görmez)
key_attributes (
  user_id uuid PK references auth.users,
  kdf_salt bytea,            -- Argon2id salt
  kdf_ops int, kdf_mem int,  -- Argon2id parametreleri
  encrypted_master_key bytea, master_key_nonce bytea,        -- KEK ile sarmalı
  recovery_encrypted_master_key bytea, recovery_nonce bytea, -- recovery key ile sarmalı
  created_at timestamptz
)

-- Şifreli TOTP girdileri (sunucu içeriği göremez)
tokens (
  id uuid PK,
  user_id uuid references auth.users,
  ciphertext bytea,          -- XChaCha20-Poly1305(token JSON)
  nonce bytea,
  version int,               -- şema/şifreleme versiyonu
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(), -- senkron/conflict için (server-side trigger ile set edilir)
  deleted bool default false -- soft delete (senkron tutarlılığı)
)

devices (user_id, device_id, name, last_seen, push_token)  -- çoklu cihaz + FCM
announcements (id, title, body, audience, created_at)       -- admin duyuruları
catalog_services (id, name, issuer, logo_url)               -- desteklenen servis kataloğu
audit_logs (id, actor, action, target, created_at)          -- admin işlem kaydı
feature_flags (key text PK, enabled bool, payload jsonb, updated_at) -- feature flag'ler
```

> **Not:** Yukarısı **şema özeti**dir, migration-ready DDL değil. Faz 3 migration'ında her tabloya eklenecek üretim detayları: `not null` + `default`'lar, PK/FK'ler (`references auth.users on delete cascade`), `devices` için composite PK `(user_id, device_id)`, senkron için `index tokens(user_id, updated_at)`, `audit_logs(created_at)` index, ve `id uuid default gen_random_uuid()`.

> **Migration adım sırası (her tablo için):** `create table` → `alter table ... enable row level security` → politikaları oluştur → **`grant`'ler en son** (`grant ... to authenticated`, gerekli yerlerde `to service_role`). Yeni Supabase projelerinde public tablolar Data API'ye **otomatik açılmaz** — explicit grant olmadan `supabase_flutter` permission hatası alır. RLS olmadan grant verme.

### RLS politikaları
- Her tabloda önce `enable row level security` (zorunlu — kapalıyken grant verilen tablo herkese açık olur).
- `tokens`, `key_attributes`, `devices`: politikalar **`to authenticated`** hedeflenir; `using (user_id = (select auth.uid()))` ve `with check (user_id = (select auth.uid()))` — kullanıcı sadece kendi satırları. (Rolü `to authenticated` ile sınırlamak `anon`'u baştan eler; `auth.uid()` anon'da `null` döner ve hiçbir satıra eşleşmez, yine de rolü açıkça belirtmek best practice.) **`(select auth.uid())` sarmalaması zorunlu:** init-plan optimizasyonu — Postgres `auth.uid()`'i her satır yerine sorgu başına bir kez değerlendirir (yalın `auth.uid()` Supabase `auth_rls_initplan` performans uyarısı verir; bkz. migration `20260606152553`).
- `announcements`, `catalog_services`, `feature_flags`: **`anon` + `authenticated` okur** (login öncesi de görünür — splash/login ekranı için). Okuma policy'si `to anon, authenticated` + her iki role `grant select`. **Yazma yalnızca server-side secret key** (service_role RLS'i bypass eder) → ayrı admin write policy yok, `authenticated`'a write grant yok. (Bu, "tüm yetkili yazma server-side" kararıyla tutarlı.)
- `audit_logs`: okuma sadece admin; insert **server-side secret key (legacy service_role) / Edge Function** üzerinden (client'tan değil).

#### Admin rolü (doğru sözdizimi)
Claim top-level `role` DEĞİL — o Postgres rolüdür. Admin işareti `app_metadata` altında taşınmalı ve oraya **Custom Access Token Hook** ile eklenmelidir (otomatik gelmez):

```sql
-- 0) Admin işaretini tutan tablo (auth.users'a doğrudan yazmak yerine)
create table public.admin_users (user_id uuid primary key references auth.users on delete cascade);
alter table public.admin_users enable row level security;  -- politika yok → client erişemez

-- 1) Custom Access Token Hook fonksiyonu: admin kullanıcının access token'ına
--    app_metadata.admin=true ekler. (Dashboard > Auth > Hooks ile etkinleştirilir.)
create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb language plpgsql stable as $$
declare claims jsonb; admin boolean;
begin
  select exists(select 1 from public.admin_users a where a.user_id = (event->>'user_id')::uuid) into admin;
  claims := event->'claims';
  if jsonb_typeof(claims->'app_metadata') is null then
    claims := jsonb_set(claims, '{app_metadata}', '{}');
  end if;
  claims := jsonb_set(claims, '{app_metadata, admin}', to_jsonb(admin));
  return jsonb_set(event, '{claims}', claims);
end;
$$;

-- 2) Hook'un izinleri: yalnızca auth admin çalıştırır; herkesten çekilir (güvenlik)
grant usage on schema public to supabase_auth_admin;   -- ZORUNLU: hook public şemaya erişebilsin
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from authenticated, anon, public;
grant select on table public.admin_users to supabase_auth_admin;  -- hook tabloyu okuyabilsin
revoke all on table public.admin_users from authenticated, anon, public;

-- 2b) ZORUNLU: admin_users RLS açık olduğu için grant tek başına yetmez —
--     supabase_auth_admin'e açık bir SELECT policy gerekir, yoksa hook satırı göremez
--     ve admin claim'i HER ZAMAN false kalır.
create policy "auth admin reads admin_users" on public.admin_users
  as permissive for select to supabase_auth_admin using (true);

-- 3) Yardımcı: is_admin() — RLS politikalarında kullanılır
create or replace function public.is_admin()
returns boolean language sql stable set search_path = '' as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'admin')::boolean, false);
$$;

-- 4) is_admin() kullanım örneği: admin'in kendi (authenticated) client'ından audit_logs OKUMASI.
--    NOT: admin-public tablolara YAZMA için ayrı policy YOK — yazma server-side secret key ile
--    (service_role RLS'i bypass eder). is_admin() yalnızca okuma kısıtlarında kullanılır.
create policy "admin reads audit_logs" on public.audit_logs
  for select to authenticated using (public.is_admin());
```

> **Önemli:** Yetkili işlemler (kullanıcı askıya alma/silme, audit_logs insert, push tetikleme) **secret key** (legacy `service_role` muadili) ile yapılır ve bu key yalnızca server-side'da (Next.js route handler / Edge Function) tutulur — tarayıcıya/uygulamaya asla gömülmez.

> **Client'ta claim okuma (tuzak):** Hook ile eklenen `app_metadata.admin` claim'i **access token (JWT) içine** yazılır; `session.user.app_metadata` nesnesinde görünmeyebilir. Middleware/uygulama bunu doğrularken `session.access_token`'ı decode edip claim'i oradan okumalı (ya da `getClaims()` kullanmalı) — `user.app_metadata`'ya güvenmek yanıltıcı olur.

> **E2E garantisi:** `tokens.ciphertext` ve `key_attributes`'taki tüm anahtar alanları sunucu için anlamsız blob'lardır. Secret key bile (RLS'i bypass etse de) bunların **içeriğini çözemez** — şifre çözme anahtarı sadece kullanıcının cihazındadır. Admin paneli yalnızca sayım/metadata görür.

### Senkron (Realtime)
- **Publication:** `alter publication supabase_realtime add table public.tokens;` (aksi halde değişiklikler yayınlanmaz). Realtime, RLS'e tabidir — kullanıcı yalnızca kendi satır olaylarını alır.
- **Pull + abonelik sırası (yarış penceresi):** Sıralama **önce abone ol, sonra pull** olmalı — yoksa pull bitişi ile abonelik aktif olması arasında gelen değişiklik kaçar. Doğru akış: (1) Realtime'a abone ol ve gelen olayları geçici tampona al, (2) `updated_at > son_sync` ile catch-up pull yap, (3) tamponlanmış olayları pull sonucuyla birleştir (idempotent, `id` bazlı upsert; `updated_at` ile en yeni kazanır). Alternatif: abonelik hazır olduktan sonra ikinci bir catch-up pull. Her durumda birleştirme `id`+`updated_at` ile idempotenttir, çift uygulama zararsızdır.
- **`updated_at` güveni server-side trigger ile:** client'ın gönderdiği zaman damgasına güvenilmez. `before insert or update` trigger ile `updated_at := now()` set edilir (clock skew'i ortadan kaldırır). **İKİ ayrı fonksiyon gerekir** — `created_at` olmayan tabloya `new.created_at := now()` yazmak `record "new" has no field "created_at"` hatası verir:
  ```sql
  -- created_at + updated_at olan tablolar (tokens, key_attributes)
  create or replace function public.touch_timestamps() returns trigger language plpgsql set search_path='' as $$
  begin if (tg_op='INSERT') then new.created_at := now(); end if; new.updated_at := now(); return new; end; $$;
  -- yalnızca updated_at olan tablolar (feature_flags)
  create or replace function public.touch_updated_at() returns trigger language plpgsql set search_path='' as $$
  begin new.updated_at := now(); return new; end; $$;
  create trigger trg_tokens_touch before insert or update on public.tokens
    for each row execute procedure public.touch_timestamps();
  ```
- **Soft delete:** silme = `update ... set deleted=true`. UPDATE olarak yayınlanır; diğer cihaz satırı gizler. Gerçek `delete` kullanılmaz (senkron tutarlılığı + Realtime DELETE payload'unun sınırlı olması nedeniyle).
- **Conflict çözümü — arrival-order LWW (Faz 3 modeli):** `updated_at` server-side `now()` ile set edildiğinden, çakışmada "son düzenleyen" değil **sunucuya son ulaşan** kazanır. Aynı token (`id` aynı) iki cihazda eşzamanlı düzenlendiğinde, sunucuya ikinci ulaşan UPDATE öncekini ezer; arada bir cihazın değişikliği sessizce kaybolabilir. Bu Faz 3 için **bilinçli kabul edilen** bir basitleştirmedir.
  - Not: "gerçekten son düzenleyen kazansın" istenirse şema `client_modified_at timestamptz` + `revision int` (+ `device_id`) alanlarıyla genişletilir ve LWW client zamanına göre yapılır; mevcut tek `id` tie-breaker olamaz çünkü aynı token için `id` zaten aynıdır.
  - Ağır çok-cihazlı kullanımda CRDT/vektör saat ileride değerlendirilir — bkz. açık kararlar.

---

## 6. Admin Panel (Next.js)

- **Stack:** Next.js (App Router) + TypeScript + Supabase JS SDK + shadcn/ui + TanStack Table + recharts.
- **Erişim:** sadece `app_metadata.admin=true` claim'li kullanıcılar; Next.js middleware'de Supabase session + claim kontrolü.
- **Yetki sınırı (kritik) — okuma modeli düzeltildi:**
  - Kullanıcı verisi (`tokens`, `key_attributes`, `devices`) RLS'i `user_id = auth.uid()` olduğundan, admin bunları **normal client ile global olarak okuyamaz**. Bu nedenle admin'in **cross-user okumaları** (kullanıcı listesi, global sayım/analitik) **server-side**, **özel şemadaki `security definer` aggregate fonksiyonu doğrudan Postgres bağlantısıyla** çağrılarak yapılır (yalnızca aggregate/metadata döndürür, ham satır değil).
  - **İki ayrı erişim yolunu karıştırma (önemli):**
    - **(a) Doğrudan Postgres bağlantısı** (`DATABASE_URL`/pooler + uygun DB rolü): private şemadaki fonksiyonları/SQL'i çağırmak için kullanılır. Cross-user aggregate okuma **bu yolla** yapılır. RLS, bağlantının DB rolüne göre uygulanır (`bypassrls`'li bir rol ya da fonksiyonun `security definer` sahibi).
    - **(b) Supabase secret key** (`sb_secret_...`, REST/Auth API kimliği): `auth.admin` (kullanıcı sil/askıya al), Storage, REST gibi **API** çağrıları için. Bu bir Postgres bağlantı bilgisi **değildir**; DB fonksiyonunu doğrudan çağırmaz.
    - Kısaca: aggregate okuma → (a); `auth.admin`/API işlemleri → (b). İkisi de server-side, ikisi de tarayıcıya gömülmez.
  - **`security definer` aggregate fonksiyon guardrail'leri (zorunlu):**
    - **Exposed olmayan özel şemada oluştur** (örn. `private` / `admin_api`) — `security definer` fonksiyonlar API ayarlarındaki "Exposed schemas" listesindeki bir şemada (public dahil expose edilmişse) **asla** tutulmaz.
    - **Çağırma yolu (çelişkiye dikkat):** Bu şema Data API'ye expose **edilmediği** için `supabase-js` `.rpc()` / `.schema()` ile **uzaktan çağrılamaz** (Data API yalnız exposed şemaları görür). Bu nedenle private fonksiyon, Next.js route handler / Edge Function içinden **doğrudan Postgres bağlantısı (server-side SQL)** ile çağrılır — secret key REST/RPC yoluyla değil. (Alternatif B: fonksiyonu bir `api` şemasına koyup expose etmek istenirse, o zaman `security definer` riskini sınırlamak için ince bir wrapper + sıkı `revoke`/`grant` ile ayrı tasarlanır; bu projede tercih A — private şema + doğrudan bağlantı.)
    - `security definer set search_path = ''` ile tanımla (search_path injection'ı engeller; tüm objelere şema-nitelikli referans ver, örn. `from public.tokens`).
    - `revoke execute on function ... from public, anon, authenticated;` — fonksiyon Data API'ye açık bırakılmaz.
    - `grant execute` yalnızca backend'in doğrudan-bağlantıda kullandığı **DB rolüne** verilir — `anon`/`authenticated` çağıramaz. (Not: bu, REST secret key'i değil, (a) yolundaki Postgres bağlantı rolüdür.)
    - Fonksiyon **yalnızca aggregate/metadata** döndürür (sayım, tarih histogramı); ham `ciphertext`/satır asla döndürmez.
    - Fonksiyon içinde girişleri doğrula (parametre injection'a karşı), gerekiyorsa fonksiyon başında admin kontrolü.
  - Yalnızca **admin-public tablolar** (`announcements`, `catalog_services`, `feature_flags`) normal `authenticated` client ile okunabilir (zaten herkese-select policy var).
  - **Yazma/yetkili işlemler** (kullanıcı askıya alma/silme, audit_logs insert, push gönderimi) yalnızca **server-side route handler / Edge Function** içinde secret key ile. Secret key asla tarayıcıya gönderilmez.
  - **Önemli:** Backend RLS'i bypass etse de (ister direct DB ister secret key) E2E nedeniyle `tokens.ciphertext` içeriğini **çözemez** — sadece metadata/sayım. Cross-user okuma "kaç token var" der, "ne içindeler" demez.
- **Supabase key terminolojisi (2026):** Supabase yeni projelerde client için **publishable key** (`sb_publishable_...`, eski `anon`), backend için **secret key** (`sb_secret_...`, eski `service_role`) öneriyor. Legacy `anon`/`service_role` **2026 sonuna kadar deprecate ediliyor** (kullanımdan kaldırma hattında); yeni projede baştan publishable/secret tercih et. Bu dokümanda "secret key" = legacy `service_role` muadili; backend-only. (Postgres rolleri `authenticated`/`service_role` ayrı konu — onlar grant/RLS hedefi olarak kalıcı.)
- **Yeni secret key kullanım detayı (Edge Function / HTTP — 401 tuzağı):** Yeni `sb_secret_...` key'ler JWT **değildir**. İstekte **`apikey` header** ile gönderilir; **`Authorization: Bearer <secret>` KULLANILMAZ** — platform onu JWT olarak parse etmeye çalışır ve `Invalid JWT` (401) döner. Bu key'leri kullanan Edge Function'larda `verify_jwt = false` (config.toml) ayarlanır ve yetkilendirme fonksiyon kodu içinde yapılır (veya `@supabase/server` ile ayrı user/admin client ayrımı). Kullanıcı isteklerini doğrulamak için kullanıcının kendi token'ı ayrıca işlenir.
- **Yetenekler:**
  - Kullanıcı yönetimi: listele, ara, askıya al/sil — listeleme/sayım cross-user olduğundan **(a) doğrudan Postgres bağlantısı + private aggregate fonksiyonu** ile; silme/askıya alma **(b) secret key + `auth.admin` API** ile. İkisi de **server-side**. İçerik değil, hesap metadata.
  - Analitik: kullanıcı/cihaz/token sayıları (toplam, içerik değil), büyüme grafikleri.
  - Duyuru/bildirim: `announcements` yaz + FCM ile push tetikle (Edge Function).
  - Servis kataloğu yönetimi: logo/issuer CRUD.
  - Feature flag'ler + audit log görüntüleme.
- **Önemli sınır:** Panel E2E nedeniyle hiçbir TOTP secret'ını çözemez/göremez — sadece metadata ve sayım.

---

## 7. Kimlik Doğrulama Akışı

- **Login parolası ≠ master parola.** Supabase Auth oturumu (email/parola, sonra OAuth) kimlik içindir; master parola E2E anahtarı içindir. İkisi ayrı tutulur (güvenlik + parola sıfırlama bağımsızlığı). **Birbirini TÜRETMEZ** (tam ayrık akış).
- `AuthRepository` interface ile soyutlanır → email/parola önce, Google/Apple sonra eklenir (kod değişmeden).

### İki bağımsız "kapı" (Faz 3 Patch 1 — uygulandı)

İki ortogonal ama **sıralı** durum: önce Supabase oturumu (kimlik), sonra vault kilidi (E2E).

```
SessionStatus (kimlik)              VaultLockStatus (E2E)
  unknown → /splash                   uninitialized → /setup
  signedOut → /auth/login             locked        → /unlock
  emailConfirmPending → /auth/confirm  unlocked      → /  (vault)
  signedIn → vault guard'ı çalışır
```

- **Birleşik guard (`sessionGuard`)** kimlik kapısını EN DIŞTA tutar; **vault guard (masterKey
  gerektiren shell) yalnız `signedIn && !linkRequired` dalında** çalışır. `unknown` boyunca
  `/splash` gösterilir → vault shell `signedIn` öncesi render edilmez (`masterKey` null crash'i yok).
- **E-posta onayı ZORUNLU** (PKCE + deep-link `dev.mustafakara.projectauth://login-callback`;
  Android intent-filter VIEW+DEFAULT+BROWSABLE, iOS `CFBundleURLTypes`). `emailConfirmPending`
  PERSIST edilir (yeniden açılışta onay ekranı; "Farklı e-posta kullan" çıkışı).
- **`onAuthStateChange` `onError` ZORUNLU** (gotrue ağ hatasını stream error olarak verir → yoksa app crash).
- **signOut** lokal vault'u (masterKey/mnemonic) network signOut'tan ÖNCE temizler (her aşamada);
  ağ hatasında bile `signedOut`'a ulaşılır (gotrue local token'ı önce siler).
- **Multi-vault per uid:** her Supabase uid için AYRI lokal vault namespace (`'<uid>/'`). İlk
  login'de uid-siz Faz 2 vault varsa açık **account-linking** onayı (`/auth/link`): ilişkilendir
  (taşı + `bmk` temizle/yeniden enroll) / yeni boş vault. Per-uid karar marker → guard döngüsü yok.
- Açılış akışı: Supabase session var mı? → (yeni cihaz: key_attributes restore — Patch 2) → master
  key cihazda unlock edilebilir mi (biyometrik)? → değilse master parola sor → vault'a gir.

---

## 7.5 Lokal → Bulut Geçiş (Faz 1 → 2 → 3)

Fazların vault üzerindeki net sorumluluğu (kavramsal çakışmayı gidermek için):

| Faz | Vault durumu | Master key | Bulut |
|---|---|---|---|
| **Faz 1** | Lokal, **şifrelenmemiş** (yalnızca `flutter_secure_storage`'ın kendi OS koruması) | yok | yok |
| **Faz 2** | Lokal, **E2E şifreli** — master key + master parola + recovery + biyometrik unlock kurulur ve lokal token'lar `masterKey` ile şifrelenir | var (cihazda) | hâlâ yok (offline demo edilebilir) |
| **Faz 3** | Aynı E2E şifreli veri **sunucuya senkronlanır** (zaten şifreli olduğu için ek şifreleme yok) | var | Supabase'e şifreli blob upload + Realtime |

> **Karar:** E2E şifreleme **Faz 2'de** tamamlanır (bulutsuz). Faz 3 yeni bir şifreleme katmanı eklemez; sadece Faz 2'de zaten `masterKey` ile şifrelenmiş token'ları `key_attributes` + `tokens` olarak sunucuya taşır. Böylece "Faz 3'te ilk kez şifreleme" çelişkisi ortadan kalkar.

**İlk login backfill akışı (Faz 3):**

1. **Tek vault soyutlaması:** `TokenRepository` Faz 1'den itibaren tek arayüz; arkasında `LocalTokenSource` ve (Faz 3'te) `RemoteSyncSource`. View/Bloc bu geçişi görmez.
2. **Token kimliği:** her token Faz 1'den itibaren stabil bir `id` (uuid) taşır → backfill'de duplicate önler.
3. **İlk login backfill:** Faz 2'de zaten `masterKey` ile şifrelenmiş lokal token'lar `tokens` tablosuna **upsert** edilir (`id` çakışırsa güncelle). İşlem idempotent — tekrar çalışırsa duplicate oluşmaz. (Faz 1'den kalan şifrelenmemiş token varsa önce Faz 2 şifrelemesinden geçer.)
4. **Sıralama:** önce master key + `key_attributes` upload, sonra token backfill. Yarıda kesilirse bir sonraki açılışta `son_sync=epoch` ile yeniden denenir.
5. **Çakışma:** aynı `id` hem lokalde hem buluttaysa (örn. ikinci cihaz) arrival-order LWW (server-side `updated_at`) uygulanır.

---

## 8. Test Stratejisi
- **Crypto & OTP:** RFC test vektörleri + altın dosya testleri (encrypt→decrypt round-trip, parola değişimi, recovery).
- **Domain/UseCase:** saf birim testleri (mock repository).
- **Bloc:** `bloc_test`.
- **Data:** Supabase'e karşı entegrasyon (test projesi) + mock.
- **E2E güvenlik testi:** sunucuya giden payload'ların gerçekten opak olduğunu doğrulayan test.
- **RLS testleri:** Kullanıcı A, B'nin `tokens`/`key_attributes` satırlarını **okuyamaz/yazamaz** (cross-user izolasyon). RLS kapalıyken test başarısız olmalı (regresyon koruması).
- **Admin claim testleri:** `is_admin()` claim'e göre doğru döner; admin claim'li kullanıcı `audit_logs`'u okuyabilir, claim'siz okuyamaz; admin-public tablolara client'tan yazma (insert/update) **grant olmadığı için** reddedilir (yazma yalnızca server-side); yetkili server-side endpoint'ler claim/secret doğrulaması olmadan reddeder.
- **Admin private function / secret key güvenlik testleri:** özel şemadaki `security definer` aggregate fonksiyonu `anon`/`authenticated` tarafından **execute edilemez** (revoke doğrulanır); fonksiyon yalnızca aggregate/metadata döndürür (ham satır/`ciphertext` sızdırmaz); fonksiyonun özel (exposed olmayan) şemada olduğu ve Data API'den çağrılamadığı doğrulanır.
- **Secret key header testi:** secret key `Authorization: Bearer` ile gönderildiğinde `Invalid JWT` (401) alınır; `apikey` header + `verify_jwt=false` ile çalışır (regresyon koruması — yanlış header kullanımı yakalanır).
- **GRANT testi:** grant verilmemiş tabloya client erişimi permission hatası verir (yanlışlıkla açık kalmasın).
- **Senkron/conflict testleri:** iki cihaz simülasyonu — eşzamanlı update'te **arrival-order LWW** davranışı doğrulanır (sunucuya son ulaşan kazanır, server-side `updated_at` ile); soft delete diğer cihazda gizlenir; Realtime publication'a ekli olmayan tabloda olay gelmez.
- **Lokal→bulut geçiş testi:** Faz 1 lokal token'larının ilk login sonrası şifreli upload/backfill'i; duplicate oluşmaması (bkz. §7.5).
