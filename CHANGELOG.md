# Changelog

Proje ilerleme günlüğü. En yeni en üstte.

## 2026-06-06 (5. tur) — Vault state sağlamlığı + token id + parse sıkılaştırma (review #5)

Dış review 5 bulgu verdi; **hepsi kaynak koddan doğrulandı, hepsi gerçekti** ve düzeltildi.

- **#1 (orta) — OtpCard state reuse'da TOTP timer durabilir:** `VaultPage` kartlara stabil
  `Key` vermiyordu; `OtpCard.didUpdateWidget` tip değişiminde (TOTP↔HOTP) timer'ı
  başlatmıyor/iptal etmiyordu. **Düzeltme:** kartlara `ValueKey(account.id)` + `_syncTimer()`
  (idempotent: zaman-bazlıysa timer başlat, HOTP'te iptal) hem `initState` hem `didUpdateWidget`'te.
- **#2 (orta) — Token'da stabil id yok (ARCHITECTURE §7.5 ile drift):** `OtpAccount`'a uuid v4
  `id` eklendi (verilmezse üretimde atanır). `VaultCubit` artık index yerine **id-bazlı**
  (`removeById`/`incrementCounter(id)`) — liste reorder/eşzamanlı değişimde yanlış öğeye
  dokunmaz. Faz 3 backfill idempotent upsert'ünün temeli. `copyWith` id'yi korur; `props`'a dahil.
- **#3 (orta) — Bilinmeyen `algorithm` sessizce SHA1'e düşüyordu:** `OtpAlgorithm.fromName`
  artık **verilmiş ama desteklenmeyen** algoritmayı (`SHA3`, `md5`, typo) `FormatException`
  ile reddeder; eksik/boş hâlâ SHA1 default. `digits`/`period` ile aynı "verilmişse doğrula" prensibi.
- **#4 (düşük) — ARCHITECTURE.md `sodium_libs` drift'i:** §1 tablosu + paket notu `sodium`
  paketine güncellendi (README/PLAN ile hizalı; `sodium_libs` discontinued uyarısı eklendi).
- **#5 (düşük) — Route diagnostic log kalıcı açıktı:** `debugLogDiagnostics: kDebugMode`
  (yalnız debug build; profile/release sessiz).
- **#6 (orta, takip turu) — HOTP'te `counter` eksikse sessizce 0 kabul ediliyordu:** Repro
  testiyle 0'a düştüğü kanıtlandı. Key URI Format'a göre HOTP'te `counter` **zorunlu** →
  `_parseBounded`'a `required` parametresi eklendi; HOTP'te eksik counter `FormatException`.
  TOTP/Steam'de counter kullanılmadığından eksiklik serbest (0). 3 yeni test.
- **Testler:** 12 yeni test (4 algorithm/id + 5 VaultCubit + 3 HOTP counter zorunluluğu).
  **Toplam 48 → 60, hepsi geçti; `analyze` temiz.** `uuid 4.5.3` eklendi.

## 2026-06-06 (4. tur) — Doküman drift + seed config (review #4)
- Test sayısı drift'i: README/PLAN/OTP_ENGINE'de kalan `38/38`·`39/39` → güncel **48/48** yapıldı.
- `config.toml` `[db.seed]` `enabled=false` (var olmayan `./seed.sql` "no files matched" WARN
  üretiyordu; seed kullanmıyoruz). Lokal `supabase start` ile WARN'ın gittiği doğrulandı.

## 2026-06-06 (3. tur) — OTP input validasyonu + uçtan uca hook doğrulaması

Dış review 2 bulgu daha verdi; ikisi de **reprodüksiyon testiyle ispatlanıp** düzeltildi.

- **#1 (orta) — Malformed otpauth:// UI crash riski:** Repro testi yazıldı ve crash KANITLANDI:
  geçersiz Base32 secret parse'ı geçiyordu ama `secretBytes` (kart render) `FormatException`
  fırlatıyordu; `period=0` `secondsRemaining`'de sıfıra bölüyordu. **Düzeltme:** validasyon
  `OtpAuthUri.parse` anına çekildi — secret Base32 decode doğrulanır, `digits` (6–8/Steam 5),
  `period` (1–600), `counter` (≥0) aralık kontrolünden geçer; geçersiz → `FormatException`.
  9 yeni test eklendi. **Test toplamı 39 → 48, hepsi geçti; `analyze` temiz.**
- **#2 (düşük) — Local config'de hook kapalı:** `config.toml`'da `[auth.hook.custom_access_token]`
  etkinleştirildi (`pg-functions://postgres/public/custom_access_token_hook`). Lokal stack
  (GoTrue) ile **gerçek login akışı uçtan uca test edildi**: signup → admin ekle → signin →
  JWT'de `app_metadata.admin=true`; normal kullanıcıda `false` (negatif kontrol). Bu, önceki
  "fonksiyonu doğrudan çağırma" testinden daha güçlü — tam auth pipeline'ı doğrular.

## 2026-06-06 (2. tur) — Dış review #2 düzeltmeleri + fresh-deploy doğrulaması

Dış review 4 bulgu daha verdi; hepsi **lokal Supabase CLI ile gerçek Postgres'te** ele alındı
(Supabase MCP bu oturumda bağlı değildi → `supabase start` ile lokal stack kuruldu).

- **#1 (yüksek) — Fresh deploy fail:** `idx_audit_logs_actor` index'i hem `init` hem `initplan`
  migration'ında oluşturuluyordu → temiz projede 2. migration "already exists" verirdi.
  `initplan` dosyasından duplicate `create index` KALDIRILDI. **Fresh deploy lokalde sıfırdan
  uygulandı, üç migration da hatasız geçti.**
- **#2 (orta) — `supabase_admin` default ACL:** `postgres` owner default'u 0003 ile daraldı ama
  `supabase_admin` owner default'u hâlâ geniş. Lokalde test edildi: migration `supabase_admin`'in
  default privilege'ını DEĞİŞTİREMİYOR ("permission denied" — Supabase kısıtı). Çözüm kod değil
  disiplin → 0003'e kalıcı uyarı eklendi: tablolar yalnız `postgres` (migration) ile oluşturulmalı.
- **#3 (orta) — Flutter init API:** Kurulu paket kaynağından kesin doğrulandı
  (`supabase_flutter 2.14.1/lib/src/supabase.dart`): `publishableKey` GERÇEK parametre, `anonKey`
  artık `@Deprecated`. `publishableKey:` hem doğru hem gelecek-uyumlu. PROJECT_INFO güncellendi.
- **#4 (düşük) — Test drift + idempotentlik:** Migration isimleri güncellendi (TEST_REPORT +
  test betiği). Token insert'lerine sabit `id` eklendi; betik 2 kez çalıştırılarak idempotentlik
  fiilen kanıtlandı (2. koşuda da count=1).
- Eklenenler: `supabase/config.toml` (CLI init), `supabase/.gitignore` (`.branches/.temp`).

## 2026-06-06 — Flutter Faz 0/1 çekirdeği + DB sertleştirme

### Flutter — Faz 0 (temel kurulum)
- Flutter projesi oluşturuldu (3.38.6, org `dev.mustafakara`, iOS+Android).
- Feature-first + katmanlı klasör yapısı: `lib/core/{otp,di,router,theme,error,config,storage}`,
  `lib/features/{vault,scan}/...`.
- Bağımlılıklar eklendi ve sürüm çakışmaları çözüldü:
  `flutter_bloc 9.1`, `go_router 17.3`, `get_it 9.2`, `injectable 2.5`, `freezed 3.2`,
  `supabase_flutter 2.14`, `sodium_libs 3.4`, `flutter_secure_storage 10.3`,
  `mobile_scanner 7.2`, `local_auth 3.0`, `crypto`, `equatable`.
- DI composition root (`configureDependencies`, get_it manuel), go_router rotaları,
  Material 3 açık/koyu tema, `main.dart` (BlocProvider + MaterialApp.router).

### Flutter — Faz 1 (OTP çekirdeği)
- `core/otp/`: Base32 (RFC 4648), HOTP (RFC 4226), TOTP (RFC 6238), Steam Guard,
  `OtpAccount` modeli, `otpauth://` parse/serialize.
- **38 RFC test vektörü yazıldı ve çalıştırıldı — hepsi geçti** (HOTP Appendix D,
  TOTP Appendix B SHA1/256/512, Base32, Steam, URI round-trip).
- Vault UI: `VaultCubit` (in-memory), `VaultPage`, geri sayımlı/kopyalanabilir `OtpCard`,
  manuel `otpauth://` ekleme. `ScanPage` placeholder (QR sırada).
- Doğrulama: `flutter analyze` temiz · `flutter test` **39/39** geçti.

### Bilinen sürüm tuzakları (pubspec'te yönetiliyor)
- ⚠️ `sodium_libs` **DISCONTINUED** → Faz 2 kriptoda `sodium` paketine geçilecek.
- `injectable` 2.x'e sabit (generator henüz 3.x desteklemiyor).
- `json_annotation` ^4.9.0'a sabit (4.12 henüz `json_serializable` ile uyumsuz).

### Supabase backend — dış review sonrası düzeltmeler
- **`0003_least_privilege_revoke` migration'ı** (canlıya uygulandı): `pg_default_acl`
  kaynaklı fazlalık `anon`/`authenticated` table privilege'ları revoke edildi
  (RLS + table-grant iki katman). Revoke sonrası security advisor yine **0 uyarı**.
- **Migration history hizalandı:** yerel tek squashed `0001` → canlıyla birebir 3
  timestamp'li dosya + `supabase/migrations/README.md`.
- **Doküman drift'leri düzeltildi:** `unused_index` 3→1 (gerçek advisor çıktısı),
  `db push` uyarısı (mevcut canlı projeye tekrar push etme), migration listeleri.
- Reddedilen 2 review bulgusu (doğrulanarak): `publishableKey` parametresi gerçek ve
  compile'da takılmaz (Context7 Dart upgrade-guide); test idempotency teorik/düşük.

## Öncesi — Mimari & Backend (özet)
- Çok turlu review + doğrulamayla olgunlaşan tam mimari (ARCHITECTURE.md).
- Supabase `authenticator-dev` projesi: 8 tablo + RLS + Custom Access Token Hook +
  private admin aggregate. Uçtan uca güvenlik testi 8/8 geçti (TEST_REPORT.md).
