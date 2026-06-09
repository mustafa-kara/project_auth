# Geliştirme Planı — Fazlı Yol Haritası

> Hedef: baştan sağlam tam mimari. Google/Apple developer hesapları hazır olmadığı için
> sosyal giriş ve push, hesap-bağımsız kısımlar bittikten sonra "takılır" — geliştirme hiçbir an bloke olmaz.
> Detaylı mimari için bkz. [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Faz 0 — Temel kurulum (1. hafta) — ÇOĞU TAMAMLANDI (2026-06-06)
- [x] Flutter projesi (3.38.6) + feature-first klasör iskeleti (`lib/core/*`, `lib/features/{vault,scan}/*`). ✅
- [x] Bağımlılıklar eklendi + sürümler çözüldü: `flutter_bloc 9.1`, `go_router 17.3`, `get_it 9.2`, `injectable 2.5`, `freezed 3.2`, `supabase_flutter 2.14`, `sodium_libs 3.4`, `flutter_secure_storage 10.3`, `mobile_scanner 7.2`, `local_auth 3.0`, `crypto`. ✅
  - 🔐 **Kripto (Faz 2'de uygulandı):** `sodium ^3.4.6` + `sodium_libs ^3.4.6+4`. sodium 4.x Dart 3.11+ ister; proje Dart 3.10.7 → 4.x çözülemez, 3.x bilinçli karar (pre-built binary, native-assets flag gerekmez; integration testleriyle kanıtlı). `sodium_libs` "discontinued" etiketli ama 3.x hattı çalışıyor. Detay docs/CRYPTO.md. `json_annotation` 4.9'a sabitlendi (4.12 henüz `json_serializable` ile uyumsuz). `injectable` 2.x'e sabit (generator 3.x'i desteklemiyor).
- [x] `core/`: tema (Material 3 açık/koyu), go_router, DI composition root (get_it manuel — injectable codegen'e sonra geçilebilir). ✅
  - [ ] l10n iskeleti, Failure tipleri, Supabase client wrapper *(Faz 3 öncesi)*.
- [x] go_router temel rotalar (`/`, `/scan`) + ekranlar + redirect guard yorum-iskeleti. ✅
- [ ] CI: `flutter analyze` + `flutter test` (şu an LOKAL geçiyor: analyze temiz, host 220/220 + integration 34/34; CI dosyası eklenecek).

## Faz 1 — Çekirdek OTP motoru (sunucusuz, tam çalışır) (1–2. hafta) — TAMAMLANDI
- [x] `core/otp/`: TOTP (RFC 6238), HOTP (RFC 4226), Steam Guard algoritmaları + Base32 (RFC 4648). ✅
- [x] **RFC test vektörlerine karşı birim testleri — GEÇTİ** (HOTP Appendix D 10 vektör, TOTP Appendix B 10 vektör SHA1/256/512, Base32, Steam, URI + input validasyon + VaultCubit id-bazlı + JSON round-trip/dayanıklılık + kalıcılık/yarış). Faz 1 sonu 79/79; **Faz 2 Patch 3 sonrası host 122/122; Patch 4 sonrası host 186/186; Patch 5 (biyometri) sonrası host 220/220** (+33: bmk attrs JSON/copyWith, VaultLockCubit biyometri (bootstrap enrolled+deviceAvailable ayrı, enableBiometric atomik catch→disable, disableBiometric, biometricUnlock unlock-guard birebir, KeyMissing→clearBiometric persist + write-fail döngü-önleme, **lifecycle inactive-vs-paused: prompt-in-flight muafiyeti**), guard /settings, Settings/UnlockPage widget) (+ integration: enrollBiometric/biometricUnlock round-trip + changePassword-sonrası-geçerli). Not: otomatik reinstall-reset (FirstRunGuard) eklenip review P0 nedeniyle GERİ ALINDI — mevcut kullanıcı vault'unu riske atardı (bkz. CHANGELOG 2026-06-07). ✅
- [x] `otpauth://` URI parse/serialize (`OtpAuthUri`) + round-trip test. ✅
- [x] Vault ekranı: kod kartları + geri sayım halkası + kopyalama + manuel `otpauth://` ekleme. ✅
- [x] Stabil token `id` (uuid v4) — `OtpAccount.id`, id-bazlı `VaultCubit` + `OtpCard ValueKey` (ARCHITECTURE §7.5 backfill temeli). ✅
- [x] QR tarama (`mobile_scanner` v7) — kamera izni akışı (iOS `NSCameraUsageDescription` + Android `CAMERA`), çift-algılama guard, flaş/kamera değiştir, izin-reddi hata UI'ı. ✅
- [x] Vault'ta **arama** (issuer/hesap/label filtresi) + HOTP sayaç kalıcılığı (her artış depoya yazılır). ✅
- [x] Lokal `flutter_secure_storage` ile token saklama, **şifrelenmemiş** (henüz master key yok, sadece OS koruması): `VaultRepository` + `OtpAccount` JSON (id/counter korur), `VaultCubit` açılışta `load()` + her mutasyonda persist. ✅
- [x] **Çıktı:** internetsiz çalışan gerçek bir authenticator — QR/manuel ekleme, kalıcı vault, arama. ✅

## Faz 2 — E2E kripto katmanı + lokal vault'u şifrele (2–3. hafta)
> İlerleme: **Patch 1–5 tamam** (crypto service, KeyManager, BIP39, encrypted repo, migration; Patch 4: Setup/Unlock/Recovery UI, route guard, lifecycle lock, corruption/integrity UI, DI rewiring, **tam UI/UX redesign** — [docs/Design.md](docs/Design.md); **Patch 5: biyometrik unlock kısayolu** — 3. wrap + OS-keystore erişim kontrolü, Settings, [docs/CRYPTO.md §11](docs/CRYPTO.md)). **Patch 6 (doküman finalizasyonu) bu turda.** Detay: [docs/CRYPTO.md](docs/CRYPTO.md).
- [x] `core/crypto/`: `CryptoService` interface + libsodium impl — Argon2id (`crypto_pwhash`), XChaCha20-Poly1305 IETF (`crypto_aead_xchacha20poly1305_ietf_*`), key wrap aynı AEAD ailesi. **`crypto_secretbox` KULLANILMADI.** ✅ (Patch 1; sodium 3.4.6+sodium_libs — sodium 4.x Dart 3.11+ ister)
- [x] Anahtar hiyerarşisi: masterKey üretimi, KEK türetme (Argon2id isolate'ta), recovery key üretimi/sarmalama (`KeyManager` setup/unlock/recoverUnlock/changePassword). ✅ (Patch 2)
- [x] Round-trip ve recovery testleri (host 122 + integration 34: encrypt/decrypt/tamper, KEK determinizmi, BIP39 resmi Trezor vektörleri, setup→unlock/recover, changePassword). ✅ (Patch 2)
- [x] **Lokal vault'u E2E şifreli hale getir:** `EncryptedVaultRepository` (token-bazlı record, unchanged-blob + bozuk-kayıt koruması, top-level/all-fail integrity), Faz 1→2 `VaultMigration` (commit-marker idempotency, id-bazlı upsert), raw-storage güvenlik testleri (secret/issuer/accountName sızmıyor). Vault artık offline+E2E. ✅ (Patch 3)
- [x] Master parola belirleme + recovery key gösterme/doğrulama UI'ı + route guard (lock state'ine göre, kendi `CubitRefreshNotifier` adapter'ı — go_router 17.x'te `GoRouterRefreshStream` yok) + lifecycle lock (paused/inactive) + corruption banner/integrity ekranı + `/auth-integrity` + `KeyAttributesStore` + `resetVault` + DI/main rewiring (StatefulWidget root, unlock sonrası `VaultCubit`) + **tam UI/UX redesign** (Geist/GeistMono gömülü, simple-icons CC0, CountdownRing, IssuerAvatar, kart/liste toggle, tap-to-copy, a11y kapıları). ✅ (Patch 4; bkz. [docs/Design.md](docs/Design.md))
- [x] Cihazda biyometrik-korumalı master key unlock — **Patch 5 TAMAM.** 3. wrap (`biometricEncryptedMasterKey`) + OS-keystore erişim kontrolü (iOS Secure Enclave + `biometryCurrentSet`; Android `strongBiometricOnly` + `enforceBiometrics`), gerçek geçit = `storage.read` (çift prompt yok), `device_info_plus` API<28 gate, Settings enable/disable + UnlockPage butonu, lifecycle inactive-vs-paused. Parola+recovery her zaman çalışır. ✅ (bkz. [docs/CRYPTO.md §11](docs/CRYPTO.md))

## Faz 3 — Supabase auth + senkron (3–5. hafta)
> **DB tarafı TAMAMLANDI ve test edildi** (2026-06-06). Proje: `authenticator-dev`. Bkz. [supabase/PROJECT_INFO.md](supabase/PROJECT_INFO.md) + [test raporu](supabase/tests/TEST_REPORT.md). Kalan maddeler Flutter client'a bağlı.
- [x] DB şeması migration'ları — **tüm tablolar** (`tokens`, `key_attributes`, `devices`, `announcements`, `catalog_services`, `audit_logs`, `feature_flags`). ✅
- [x] Her tabloda sıra: `create table` → **`enable row level security`** → politikalar → **explicit `grant`**. ✅ (advisor security: 0 uyarı)
- [x] `admin_users` + `custom_access_token_hook` + `is_admin()` + tüm hook izinleri **+ `supabase_auth_admin` SELECT policy**. Hook Dashboard'dan etkinleştirildi. ✅ (uçtan uca test: admin claim true/false doğru)
- [x] `updated_at` trigger (`touch_timestamps`/`touch_updated_at`) + `alter publication supabase_realtime add table tokens`. ✅
- [x] **cross-user RLS testi** + with check + audit_logs admin-only + FK cascade. ✅ (8/8 test geçti)
- [x] **Patch 1 — `AuthRepository` (email/parola) + kayıt/giriş/çıkış akışı.** ✅ Supabase init
  (PKCE), `SessionCubit` (signedIn/out/emailConfirmPending), iki-kapı guard (kimlik + vault),
  e-posta onay deep-link, signOut→vault kilit + ağ-hatası-dirençli `signedOut`, multi-vault per uid
  (namespace + account-linking + legacy migration `bmk` temizleme). **host 220→257.** *(Flutter)*
- [x] **Patch 2 — `key_attributes` upload/restore + bytea codec.** ✅ Zaten-şifreli metadata (KDF + KEK/
  recovery-wrapped master key + nonce'lar) sunucuya backfill (unlocked'ta guard'lı insert, server-wins) +
  yeni cihazda restore → master parola → unlock. `ByteaCodec` (tek nokta), `SupabaseKeyAttributesRepository`,
  `restoring`/`restoreFailed` state + `RestoreFailedPage` (ağ hatasında setup'a düşmez). masterKey/KEK/secret/bmk
  ASLA sunucuya gitmez. **Token sync DEĞİL (Patch 3).** **host 257→293.** *(Flutter)*
- [ ] **Patch 3** — Şifreli token push/pull; **payload opaklık testi**; arrival-order LWW + soft delete;
  Realtime tetikleyici → REST pull. **Lokal→bulut backfill** (idempotent upsert, ARCHITECTURE §7.5). *(Flutter)*
- [ ] **Patch 4** — `devices` kayıt (stable device_id + last_seen) + `catalog_services`/`feature_flags`/`announcements` okuma. *(Flutter)*
- [x] Uygulama kilidi (biyometrik) feature'ı — **Faz 2 Patch 5'te tamamlandı.** ✅

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
