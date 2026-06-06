# Geliştirme Planı — Fazlı Yol Haritası

> Hedef: baştan sağlam tam mimari. Google/Apple developer hesapları hazır olmadığı için
> sosyal giriş ve push, hesap-bağımsız kısımlar bittikten sonra "takılır" — geliştirme hiçbir an bloke olmaz.
> Detaylı mimari için bkz. [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Faz 0 — Temel kurulum (1. hafta) — ÇOĞU TAMAMLANDI (2026-06-06)
- [x] Flutter projesi (3.38.6) + feature-first klasör iskeleti (`lib/core/*`, `lib/features/{vault,scan}/*`). ✅
- [x] Bağımlılıklar eklendi + sürümler çözüldü: `flutter_bloc 9.1`, `go_router 17.3`, `get_it 9.2`, `injectable 2.5`, `freezed 3.2`, `supabase_flutter 2.14`, `sodium_libs 3.4`, `flutter_secure_storage 10.3`, `mobile_scanner 7.2`, `local_auth 3.0`, `crypto`. ✅
  - ⚠️ **`sodium_libs` DISCONTINUED** → Faz 2'de `sodium` paketine geç (pub uyarısı; API neredeyse aynı). `json_annotation` 4.9'a sabitlendi (4.12 henüz `json_serializable` ile uyumsuz). `injectable` 2.x'e sabit (generator 3.x'i desteklemiyor).
- [x] `core/`: tema (Material 3 açık/koyu), go_router, DI composition root (get_it manuel — injectable codegen'e sonra geçilebilir). ✅
  - [ ] l10n iskeleti, Failure tipleri, Supabase client wrapper *(Faz 3 öncesi)*.
- [x] go_router temel rotalar (`/`, `/scan`) + ekranlar + redirect guard yorum-iskeleti. ✅
- [ ] CI: `flutter analyze` + `flutter test` (şu an LOKAL geçiyor: analyze temiz, 60/60 test; CI dosyası eklenecek).

## Faz 1 — Çekirdek OTP motoru (sunucusuz, tam çalışır) (1–2. hafta) — ÇEKİRDEK TAMAMLANDI
- [x] `core/otp/`: TOTP (RFC 6238), HOTP (RFC 4226), Steam Guard algoritmaları + Base32 (RFC 4648). ✅
- [x] **RFC test vektörlerine karşı birim testleri — GEÇTİ** (HOTP Appendix D 10 vektör, TOTP Appendix B 10 vektör SHA1/256/512, Base32, Steam, URI + input validasyon + VaultCubit id-bazlı). Proje toplamı **60/60**. ✅
- [x] `otpauth://` URI parse/serialize (`OtpAuthUri`) + round-trip test. ✅
- [x] Vault ekranı: kod kartları + geri sayım halkası + kopyalama + manuel `otpauth://` ekleme. ✅
- [x] Stabil token `id` (uuid v4) — `OtpAccount.id`, id-bazlı `VaultCubit` + `OtpCard ValueKey` (ARCHITECTURE §7.5 backfill temeli). ✅
- [ ] QR tarama (`mobile_scanner`) — kamera izni akışı + scan_page doldurma. *(sonraki adım)*
- [ ] Vault'ta **arama** + HOTP "sonraki kod" kalıcılığı.
- [ ] Lokal `flutter_secure_storage` ile token saklama, **şifrelenmemiş** (henüz master key yok, sadece OS koruması). *(sonraki adım — şu an in-memory)*
- [ ] **Çıktı:** internetsiz çalışan gerçek bir authenticator. (Çekirdek hazır; kalıcılık + QR ile demo tam olur.)

## Faz 2 — E2E kripto katmanı + lokal vault'u şifrele (2–3. hafta)
- [ ] `core/crypto/`: `CryptoService` interface + libsodium impl — Argon2id (`crypto_pwhash`), XChaCha20-Poly1305 IETF (`crypto_aead_xchacha20poly1305_ietf_*`), key wrap aynı AEAD ailesi. **`crypto_secretbox` kullanma.**
- [ ] Anahtar hiyerarşisi: masterKey üretimi, KEK türetme, recovery key üretimi/sarmalama.
- [ ] Round-trip ve recovery testleri (altın dosyalar).
- [ ] Master parola belirleme + recovery key gösterme/doğrulama UI'ı.
- [ ] Cihazda biyometrik-korumalı master key unlock (OS keystore access-control; bkz. ARCHITECTURE §2.3).
- [ ] **Lokal vault'u E2E şifreli hale getir:** Faz 1'in token'larını `masterKey` ile şifrele. Artık vault offline+E2E (bulut hâlâ yok). Faz 3 sadece bu şifreli veriyi senkronlar — yeni şifreleme eklemez (bkz. ARCHITECTURE §7.5).

## Faz 3 — Supabase auth + senkron (3–5. hafta)
> **DB tarafı TAMAMLANDI ve test edildi** (2026-06-06). Proje: `authenticator-dev`. Bkz. [supabase/PROJECT_INFO.md](supabase/PROJECT_INFO.md) + [test raporu](supabase/tests/TEST_REPORT.md). Kalan maddeler Flutter client'a bağlı.
- [x] DB şeması migration'ları — **tüm tablolar** (`tokens`, `key_attributes`, `devices`, `announcements`, `catalog_services`, `audit_logs`, `feature_flags`). ✅
- [x] Her tabloda sıra: `create table` → **`enable row level security`** → politikalar → **explicit `grant`**. ✅ (advisor security: 0 uyarı)
- [x] `admin_users` + `custom_access_token_hook` + `is_admin()` + tüm hook izinleri **+ `supabase_auth_admin` SELECT policy**. Hook Dashboard'dan etkinleştirildi. ✅ (uçtan uca test: admin claim true/false doğru)
- [x] `updated_at` trigger (`touch_timestamps`/`touch_updated_at`) + `alter publication supabase_realtime add table tokens`. ✅
- [x] **cross-user RLS testi** + with check + audit_logs admin-only + FK cascade. ✅ (8/8 test geçti)
- [ ] `AuthRepository` (email/parola) + kayıt/giriş akışı. *(Flutter)*
- [ ] `key_attributes` upload/download; cihazlar arası master key kurtarma. *(Flutter)*
- [ ] Şifreli token push/pull; **payload opaklık testi** (client). *(Flutter)*
- [ ] **Lokal→bulut backfill** (idempotent upsert, bkz. ARCHITECTURE §7.5). *(Flutter)*
- [ ] Supabase Realtime ile gerçek zamanlı çoklu cihaz senkron + arrival-order LWW + soft delete. *(Flutter)*
- [ ] Uygulama kilidi (biyometrik/PIN) feature'ı. *(Flutter)*

## Faz 4 — Sosyal giriş + push *(developer hesapları hazır olunca)*
- [ ] Google Sign-In + Apple Sign-In (`AuthRepository`'ye eklenir, çekirdek değişmez).
- [ ] FCM kurulumu (Firebase projesi + APNs sertifikası).
- [ ] Cihaz push token kaydı (`devices`) + admin→push Edge Function.

## Faz 5 — Import/Export + servis kataloğu (5–6. hafta)
- [ ] Import: Google Authenticator (migration payload), Aegis, 2FAS.
- [ ] Export (şifreli yedek).
- [ ] `catalog_services` ile issuer logo/eşleştirme.
- [ ] Etiket/klasör organizasyonu.

## Faz 6 — Admin paneli (Next.js) (paralel başlanabilir, 3. fazda tablolar hazır olunca)
- [ ] Next.js + Supabase SDK + shadcn/ui + admin claim middleware (`app_metadata.admin`).
- [ ] **Okuma:**
  - Admin-public tablolar (`announcements`, `catalog_services`, `feature_flags`) → normal `authenticated` client.
  - **İki erişim yolu (karıştırma):** (a) cross-user **okuma** → server-side **doğrudan Postgres bağlantısı** (`DATABASE_URL`/pooler + DB rolü) ile özel şemadaki `security definer` aggregate fonksiyonu (ham satır değil, sayım/metadata). (b) `auth.admin`/REST işlemleri → **secret key** (REST API kimliği, DB bağlantısı değil). Secret key DB fonksiyonunu doğrudan çağırmaz.
  - **Cross-user okuma** RLS `user_id=auth.uid()` nedeniyle client ile yapılamaz; private şema Data API'ye expose edilmediğinden `supabase-js .rpc()` ile de çağrılamaz → (a) yolu. Guardrail'ler: özel şema + `set search_path=''` + `revoke execute from public/anon/authenticated` + `grant execute` yalnızca backend DB rolüne. Bkz. ARCHITECTURE §6.
- [ ] **Yazma/yetkili işlemler server-side route handler / Edge Function + secret key ile** (secret key tarayıcıya gömülmez):
  - Kullanıcı askıya alma/silme (`auth.admin` API).
  - `audit_logs` insert; her yetkili işlem loglanır.
  - Duyuru CRUD + FCM push tetikleme.
- [ ] **Key terminolojisi:** yeni projede client → publishable key, backend → secret key (legacy `anon`/`service_role` 2026 sonuna kadar deprecate ediliyor — baştan yenisini kullan). Yeni secret key Edge Function/HTTP'de **`apikey` header** ile, `Bearer` ile DEĞİL (yoksa `Invalid JWT` 401); ilgili function'da `verify_jwt=false`. Bkz. ARCHITECTURE §6.
- [ ] Servis kataloğu CRUD; `feature_flags` yönetimi; audit log görüntüleme.

## Faz 7 — Sertleştirme & yayın
- [ ] Güvenlik gözden geçirmesi (anahtar yaşam döngüsü, bellek temizleme, screenshot engelleme).
- [ ] Erişilebilirlik, dil desteği, store materyalleri.
- [ ] App Store / Play Store yayını (Apple developer hesabı gerekli).

---

## Bağımlılık takvimi (kritik yol)
```
Faz 0 → Faz 1 → Faz 2 → Faz 3 ─┬─► Faz 5 ─► Faz 7
                                └─► Faz 6 (admin, paralel)
Faz 4 (sosyal+push) ── developer hesapları hazır olunca herhangi bir noktada takılır
```

## Şimdiki engeller / kullanıcı aksiyonu
- [x] **Supabase projesi aç** ✅ — `authenticator-dev` açıldı, migration uygulandı, hook etkin.
- [ ] Google Play + Apple Developer hesapları (Faz 4 ve yayın için — beklerken Faz 0–3 ilerler).
- [ ] Firebase projesi (Faz 4 push için).
- [ ] (Faz 6 öncesi) Backend DB rolü + `private` şema grant (admin aggregate çağrısı için).

## Açık tasarım kararları (ileride netleştirilecek)
- Conflict çözümü **arrival-order LWW** ile başlıyor (sunucuya son ulaşan kazanır; bkz. ARCHITECTURE §5); çok cihazlı ağır kullanımda CRDT/gerçek-modified-time'a geçiş değerlendirilebilir.
- Recovery key formatı: BIP39 kelime listesi mi hex mi? (UX testiyle karar.)
- Admin analitik metrikleri E2E nedeniyle yalnızca metadata; hangi metrikler tam liste netleşecek.
