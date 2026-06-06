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
| Flutter — Faz 1 OTP çekirdeği | ✅ TOTP/HOTP/Steam/Base32 + `otpauth://` (validasyonlu, stabil token id) + vault UI · **60/60 test geçti** (RFC vektörleri + validasyon + VaultCubit + widget) · `analyze` temiz |
| Flutter — Faz 1 kalanı | ⏳ QR tarama + secure_storage kalıcılık + arama |
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
flutter test             # 60/60 geçiyor (OTP RFC vektörleri + URI validasyon + VaultCubit + widget smoke)
flutter run              # cihaz/emülatörde çalıştır
```

**Klasör yapısı** (feature-first + katmanlı):
```
lib/
  core/
    otp/        TOTP/HOTP/Steam/Base32 motoru + otpauth:// parse (saf Dart, test edilir)
    di/         get_it composition root (configureDependencies)
    router/     go_router rotaları (Routes sabitleri)
    theme/      Material 3 açık/koyu tema
  features/
    vault/      presentation/{bloc,pages,widgets} — VaultCubit, VaultPage, OtpCard
    scan/       presentation — ScanPage (QR, Faz 1 ilerleyen adım)
  main.dart     DI init + MaterialApp.router + VaultCubit provider
test/
  core/otp/     RFC 4226/6238 test vektörleri + URI parse testleri
```

> **OTP çekirdeği detayı:** [docs/OTP_ENGINE.md](docs/OTP_ENGINE.md).
>
> ⚠️ **`sodium_libs` paketi DISCONTINUED.** Faz 2 (kripto) başlarken `sodium` paketine geçilecek (API neredeyse aynı; XChaCha20-Poly1305 IETF + Argon2id kararı değişmez).

---

## Önemli güvenlik notları (geliştiriciye)

- **Login parolası ≠ master parola.** Supabase oturumu kimlik için; master parola E2E anahtarı için. Ayrı tutulur.
- **Secret key (`sb_secret_...`) asla client'a gömülmez** — yalnızca backend (Next.js / Edge Function).
- **libsodium:** XChaCha20-Poly1305 için `crypto_aead_xchacha20poly1305_ietf_*` kullan; `crypto_secretbox` (XSalsa20) **kullanma**.
- Tüm DB erişimi RLS'e tabidir; cross-user izolasyon test edildi.
