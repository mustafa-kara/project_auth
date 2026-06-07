# Authenticator App

E2E (uçtan uca) şifreli, çoklu cihaz senkronize **TOTP/HOTP authenticator** — Ente Auth / Google Authenticator benzeri.

- **Mobil:** Flutter (iOS + Android), MVVM + Bloc, go_router, feature-first mimari
- **Backend:** Supabase (Auth + Postgres + Realtime + RLS)
- **Admin panel:** Next.js / React (Faz 6)
- **Şifreleme:** E2E — TOTP secret'ları cihazda libsodium (XChaCha20-Poly1305 + Argon2id) ile şifrelenir; sunucu yalnızca opak blob görür.

> **Güvenlik özü:** Sunucu (Supabase) hiçbir koşulda açık TOTP secret'ını göremez. Şifre çözme anahtarı yalnızca kullanıcının cihazında ve master parolasındadır.

---

## Dokümantasyon haritası

| Dosya | İçerik |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Tam mimari: güvenlik/kripto modeli, katmanlar, Supabase şeması + RLS, admin panel, auth akışı, senkron, test stratejisi |
| [PLAN.md](PLAN.md) | Fazlı yol haritası (Faz 0–7), bağımlılık takvimi, durum |
| [supabase/PROJECT_INFO.md](supabase/PROJECT_INFO.md) | Canlı Supabase projesi: URL, publishable key, deployment checklist |
| [supabase/migrations/](supabase/migrations/) | Çalıştırılabilir SQL migration'ları |
| [supabase/tests/TEST_REPORT.md](supabase/tests/TEST_REPORT.md) | Güvenlik & RLS test raporu (uçtan uca, geçti) |
| [supabase/tests/security_rls_tests.sql](supabase/tests/security_rls_tests.sql) | Tekrar-çalıştırılabilir güvenlik test betiği |
| [docs/OTP_ENGINE.md](docs/OTP_ENGINE.md) | OTP çekirdeği (TOTP/HOTP/Steam/Base32) teknik notu + RFC test durumu |
| [CHANGELOG.md](CHANGELOG.md) | Sürüm/ilerleme günlüğü |

---

## Mevcut durum (2026-06-06)

| Aşama | Durum |
|---|---|
| Mimari & plan | ✅ Olgunlaştı (çok turlu review + doğrulama) |
| Supabase backend (Faz 3 DB) | ✅ Uygulandı + güvenlik taraması temiz (0 uyarı) + uçtan uca test (8/8) + least-privilege sertleştirme (0003) |
| Custom Access Token Hook | ✅ Etkin + admin claim doğrulandı |
| Flutter — Faz 0 iskelet | ✅ Proje + feature-first yapı + DI/router/tema + bağımlılıklar |
| Flutter — Faz 1 OTP çekirdeği | ✅ TOTP/HOTP/Steam/Base32 + `otpauth://` (validasyonlu, stabil token id) + vault UI + QR tarama (mobile_scanner) + secure_storage kalıcılık + arama · `analyze` temiz |
| Flutter — Faz 2 E2E kripto (Patch 1–3) | ✅ `CryptoService`/SodiumSumo (XChaCha20-Poly1305 IETF + Argon2id), `KeyManager` (setup/unlock/recovery/changePassword), kendi BIP39 (MIT, resmi vektörler), `EncryptedVaultRepository` (token-bazlı, unchanged-blob + bozuk-kayıt koruması, integrity), Faz 1→2 migration (commit-marker, upsert) · **host 122/122 + integration 34/34** (sim) |
| Flutter — Faz 2 UI/oturum (Patch 4) | ✅ Setup/Unlock/Recovery UI + route guard (lock state'ine göre) + lifecycle lock (paused/inactive) + corruption banner/integrity ekranı + `KeyAttributesStore`/`resetVault` + DI/main rewiring + **tam UI/UX redesign** (Geist/GeistMono gömülü, simple-icons CC0, CountdownRing, IssuerAvatar, kart/liste toggle, tap-to-copy, a11y) · **host 186/186** · bkz. [docs/Design.md](docs/Design.md) |
| Flutter — Faz 2 kalanı (Patch 5–6) | ⏳ biyometri ayrı mini-faz (Patch 5, ertelendi) · doküman finalizasyonu (Patch 6) |
| Admin paneli (Next.js) | ⏳ Faz 6 |

**Backend canlı proje:** `authenticator-dev` (Supabase, eu-central-1, PG17). Detay: [PROJECT_INFO.md](supabase/PROJECT_INFO.md).

---

## Fazlar (özet)

0. **Temel kurulum** — Flutter iskeleti, bağımlılıklar, go_router, DI
1. **OTP motoru** — TOTP/HOTP/Steam (RFC 6238/4226), QR tarama, vault UI (sunucusuz çalışır)
2. **E2E kripto** — libsodium, master key + recovery key, lokal vault şifreleme
3. **Supabase auth + senkron** — DB ✅ hazır; Flutter client tarafı sırada
4. **Sosyal giriş + push** — Google/Apple Sign-In, FCM *(developer hesapları gerekli)*
5. **Import/Export + katalog** — Google Auth / Aegis / 2FAS göçü
6. **Admin paneli** — Next.js, analitik, duyuru/push, feature flag
7. **Sertleştirme & yayın** — güvenlik gözden geçirme, store

Detaylı görev listesi: [PLAN.md](PLAN.md).

---

## Geliştirme

### Backend (Supabase)
Migration'lar `supabase/migrations/` altında (3 dosya, timestamp sıralı — bkz.
[supabase/migrations/README.md](supabase/migrations/README.md)).

> ⚠️ **Mevcut canlı projeye (`authenticator-dev`) bu migration'lar ZATEN uygulanmıştır.**
> Tekrar `db push` etme — "relation already exists" hatası alırsın.

**Yeni/temiz bir projeye** uygulamak için:
```bash
supabase link --project-ref <YENİ_REF>
supabase db push          # üç migration'ı sırayla uygular
# veya migration dosyalarını Supabase SQL editöründe / MCP ile sırayla çalıştır
```
Güvenlik testlerini çalıştırmak için: [supabase/tests/security_rls_tests.sql](supabase/tests/security_rls_tests.sql).

**Manuel deployment adımları** (migration kapsamı dışında) için bkz. [PROJECT_INFO.md](supabase/PROJECT_INFO.md) → Deployment Checklist.

### Flutter
Proje kökü Flutter uygulamasıdır (`lib/`, `pubspec.yaml`). Gereken: Flutter 3.38+.

```bash
flutter pub get
flutter analyze          # lint — şu an temiz
flutter test             # 186/186 host (OTP RFC vektörleri + URI validasyon + VaultCubit + crypto blob/attrs/BIP39 + VaultLockCubit/guard/KeyAttributesStore + lifecycle arka-plan-yarışı + corruption/integrity-guard/a11y widget + CountdownColors + recovery-verify/textScaler)
flutter run              # cihaz/emülatörde çalıştır
```

> **libsodium testleri cihaz/simülatörde:** `sodium_libs` platform plugin'i plain
> `flutter test` VM host'unda yüklenmez → kripto round-trip testleri
> `integration_test/` altında (34 test: sodium service 8 + KeyManager 8 +
> encrypted vault/migration 18). Çalıştır: `flutter test integration_test/ -d <device>`.

**Klasör yapısı** (feature-first + katmanlı):
```
lib/
  core/
    otp/        TOTP/HOTP/Steam/Base32 motoru + otpauth:// parse (saf Dart, test edilir)
    di/         get_it composition root (configureDependencies)
    router/     go_router rotaları (Routes sabitleri)
    theme/      Material 3 açık/koyu tema
  features/
    vault/      data/ — VaultRepository (secure_storage kalıcılık)
                presentation/{bloc,pages,widgets} — VaultCubit, VaultPage (arama), OtpCard
    scan/       presentation — ScanPage (mobile_scanner QR tarama)
  main.dart     DI init + MaterialApp.router + VaultCubit provider
test/
  core/otp/     RFC 4226/6238 test vektörleri + URI parse testleri
```

> **OTP çekirdeği detayı:** [docs/OTP_ENGINE.md](docs/OTP_ENGINE.md).
>
> 🔐 **Kripto paket kararı (Faz 2'de uygulandı):** `sodium: ^3.4.6` + `sodium_libs: ^3.4.6+4`. `sodium 4.x` Dart SDK `^3.11.0` ister; proje Dart `3.10.7` (Flutter 3.38.6 stable) → **4.x çözülemez**, bu yüzden 3.x bilinçli ve doğru karardır. `sodium_libs` pub'da "discontinued" etiketli ama pre-built libsodium binary'lerini yükler ve native-assets/experiment flag GEREKTİRMEZ; 3.x hattı çalışır. İleride Flutter Dart 3.11+'a yükselince 4.x native assets'e geçiş ayrı bir küçük migration olur. XChaCha20-Poly1305 IETF + Argon2id algoritma kararı değişmez. Detay: [docs/CRYPTO.md](docs/CRYPTO.md).

---

## Önemli güvenlik notları (geliştiriciye)

- **Login parolası ≠ master parola.** Supabase oturumu kimlik için; master parola E2E anahtarı için. Ayrı tutulur.
- **Secret key (`sb_secret_...`) asla client'a gömülmez** — yalnızca backend (Next.js / Edge Function).
- **libsodium:** XChaCha20-Poly1305 için `crypto_aead_xchacha20poly1305_ietf_*` kullan; `crypto_secretbox` (XSalsa20) **kullanma**.
- Tüm DB erişimi RLS'e tabidir; cross-user izolasyon test edildi.
