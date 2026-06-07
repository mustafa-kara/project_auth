# Tasarım Sistemi — `project_auth` (Faz 2 / Patch 4)

> Bu doküman uygulamanın **görsel sınırlarını** ve tasarım dilini tanımlar. Patch 4
> UI/UX redesign'ı buna göre uygulanır; sonraki fazlar bu token'ları genişletir,
> ihlal etmez. `/ui-ux-pro-max` + `/frontend-design` skill'leri + Ente Auth / Aegis /
> 2FAS / Raivo araştırması ile kararlaştırıldı (kullanıcı onaylı).

## 1. Ürün kimliği

`project_auth` — **offline-first, E2E şifreli, gizliliğe saygılı** bir authenticator
(TOTP/HOTP/Steam). Tasarım yönü: **Precision / Technical** — koyu, yüksek kontrastlı,
"terminal/precision" hissi. Hedef: güven + teknik yetkinlik sinyali. Ruhen Ente/Aegis
ailesinde ama daha karakterli (jenerik Material değil).

## 2. Tasarım ilkeleri

1. **Kod okunabilirliği her şeyden önce.** OTP kodu ekranın en net, en büyük, en
   kolay kopyalanan öğesidir.
2. **Renk asla tek sinyal değil.** Geri sayım hem renk (yeşil→amber→kırmızı) hem
   sayı/şekil taşır (color-not-only — renk körlüğü güvenliği).
3. **Güvenlik UI ile hissettirilir, uzun metinle değil.** Kilit durumu, doğrulama,
   şifreli rozet görsel ipuçlarıyla; teknik jargon (AES/Argon2id) ön planda değil.
4. **Offline + gizlilik.** Hangi servisleri kullandığın cihazdan çıkmaz: ikonlar
   bundle'dan gelir, runtime logo/favicon çekme YOK.
5. **Platform saygısı.** Safe area, ≥44pt dokunma hedefi, reduced-motion, dynamic
   type (büyük metin) — taşma/jitter olmadan.

## 3. Tasarım token'ları

Tüm bileşenler **semantic token** kullanır; bileşen içinde ham hex YOK. Token'lar
`lib/core/ui/tokens.dart` (spacing/radius/duration + `ColorScheme` dışı renkler bir
`ThemeExtension` olarak) ve `lib/core/theme/app_theme.dart`'ta tanımlanır.

### 3.1 Renk (dark-first, light tam destekli)

İki tema **birlikte** tasarlanır; kontrast her iki modda ayrı doğrulanır. Güven-mavi
primary + katmanlı koyu yüzeyler + anlamsal durum renkleri:

| Rol | Anlam |
|-----|-------|
| `primary` | Marka mavisi — birincil aksiyon, aktif durum, sayaç "bol" tonu desteği |
| `surface` / `surfaceContainer*` | Katmanlı koyu/açık yüzeyler (kart < sheet < dialog) |
| `success` (yeşil) | Sayaç bol (kalan süre yüksek), başarı geri bildirimi |
| `warning` (amber) | Sayaç azalıyor |
| `error` / `destructive` (kırmızı) | Sayaç kritik (<5sn), yıkıcı aksiyon, hata |
| `onSurface` / `onSurfaceVariant` | Birincil / ikincil metin |

- Taban: `ColorScheme.fromSeed` + el ile ayarlanmış surface tonları (düz indigo
  `#3D5AFE` seed'i bırakılır, security-blue paletine geçilir).
- **Kontrast hedefi:** gövde metni ≥ 4.5:1; OTP kodu hedef 7:1 (her iki tema).

### 3.2 Tipografi

- **Geist** (display/başlık + gövde) + **Geist Mono** (OTP kodları, sayaç, recovery
  kelimeleri). Inter/Roboto **kullanılmaz** (jenerik — frontend-design kuralı).
- Geist latin-ext → **Türkçe glif** (ş/ğ/ı/İ/ç/ö/ü) destekli; bundle öncesi teyit edilir.
- Kod/sayaç stilleri: `Geist Mono` + `FontFeature.tabularFigures()` (sabit genişlik →
  her tikte layout kaymaz). Kod gruplaması: 6-hane `123 456`, 8-hane/Steam ham.
- **Fontlar gömülür** (`assets/fonts/`, `pubspec.yaml fonts:`). `google_fonts` paketi
  KULLANILMAZ (runtime fetch → offline + gizlilik ihlali).

### 3.3 Spacing / şekil / elevation / motion

- **Spacing:** 4/8dp skalası (4, 8, 12, 16, 24, 32...). Bölüm ritmi 16/24/32.
- **Radius:** kart ~16, küçük öğe ~8 (token).
- **Elevation:** tutarlı skala (kart < sheet < dialog); rastgele gölge yok.
- **Motion:** 150–300ms; yalnız transform/opacity; ease-out giriş, daha hızlı çıkış;
  `MediaQuery.disableAnimations`/reduced-motion'a saygı (animasyon kapanır, bilgi kalır).

## 4. Bileşen envanteri

| Bileşen | Notlar |
|---------|--------|
| `OtpCard` | İki varyant: **spacious kart** (varsayılan) ↔ **kompakt liste**. Kod hep görünür; karta/koda tek tap = panoya kopyala + kısa onay (tap-to-reveal YOK; Google/Aegis varsayılanı). HOTP'te sayaç yerine refresh ikon butonu (sonraki kod). Ayrı kopyala ikon butonu YOK — tüm kart kopyalama hedefidir. |
| `CountdownRing` | Dairesel halka; değer `remaining/period`; renk **healthy → warning (kalan ≤%33) → critical (kalan ≤5sn, MUTLAK — periyottan bağımsız)** + **ortada kalan saniye**. Kritik eşiği `remaining`'in saniyesidir, oranı değil → period=60'ta da period=15'te de son 5sn kritik. <5sn hafif scale-pulse (reduced-motion'da kapalı). HOTP'te halka yerine refresh aksiyonu. |
| `IssuerAvatar` | simple-icons logosu (eşleşirse) veya **baş harf + deterministik renkli daire** fallback. |
| Butonlar | Birincil (`FilledButton` tabanlı) + ikincil/ghost. Her ekranda tek birincil CTA. |
| `AppTextField` | Görünür label (placeholder-only değil), inline hata, helper text, parola show/hide, submit'te clear. |
| `AuthScaffold` | Auth akışı ortak iskeleti: ikon + başlık (headlineSmall) + açıklama (onSurfaceVariant) + kaydırılabilir gövde + sabit alt CTA alanı. Safe-area, tutarlı `Gap`, dynamic-type taşma yok. Tüm setup/unlock/recovery/integrity ekranları bunu kullanır. |
| `MnemonicGrid` | Recovery key (24 kelime) **2 sütun × 12 satır numaralı grid** (sol 1–12, sağ 13–24), GeistMono. Tüm kelimeler tek ekranda görünür (dikey liste DEĞİL → kullanıcı hepsini görmeden ilerleyemez). |
| `AppBanner` | Corruption uyarısı (aksiyonlu). |
| Dialog | Yıkıcı aksiyon onayı (çift onaylı reset). |
| State view'ları | empty / no-match / loading (skeleton) / integrity hata / auth-integrity. |

## 5. Erişilebilirlik kontratı

- **Kontrast:** gövde ≥ 4.5:1, ikincil ≥ 3:1, OTP kodu hedef 7:1 — her iki temada ayrı doğrulanır.
- **Dokunma:** kod alanı ve tüm aksiyonlar ≥ 44pt; gerekirse `hitSlop`/padding ile genişletilir.
- **Semantics:** kod + kalan süre tek etikette (`"Kod 123456, 8 saniye kaldı"`); her
  saniye değil, materyal değişimde duyuru. İkon-only butonlara erişilebilirlik etiketi.
- **color-not-only:** sayaç durumu renk + sayı (+ <5sn pulse) ile; renk tek başına anlam taşımaz.
- **reduced-motion:** animasyon kapanır, renk + sayı + içerik korunur.
- **dynamic type:** büyük metin ölçeğinde (örn. textScaler 2.0) taşma/overflow yok.
- **Test kapısı:** Semantics etiketi + textScaler 2.0 overflow + reduced-motion widget testleri zorunlu.

## 6. Sınırlar — Patch 4 KAPSAM DIŞI

Bilinçli olarak sonraki fazlara bırakıldı (scope drift önlemi):

- **Biyometrik unlock** → Patch 5 (ayrı mini-faz).
- **Klasör / etiket / favori / sıralama** → ileride.
- **Çoklu dil (l10n)** → şimdilik metinler Türkçe hardcoded.
- **AMOLED ayrı tema / Material You dinamik renk** → ileride (Patch 4 = dark + light, ikisi eksiksiz).
- **Gelişmiş gesture / widget (home-screen)** → kapsam dışı.
- **Tüm simple-icons seti** → Patch 4 yalnız **curated yaygın-servis alt-kümesi** gömer;
  eşleşmeyen issuer'lar baş-harf fallback'e düşer.

## 7. Asset lisansları (kaynaktan teyit edilir — körü körüne kabul yok)

- **Geist / Geist Mono** — SIL Open Font License (OFL). `assets/fonts/`'a gömülmeden
  önce lisans + latin-ext glif kapsamı teyit edilir; attribution bu dosyada ve font
  klasöründe tutulur.
- **simple-icons** — CC0 (public domain). Curated SVG alt-kümesi `assets/icons/`'a
  gömülür; tek-renkli → tema rengiyle boyanır. CC0 kaynaktan teyit edilir; attribution
  `assets/icons/README` + bu dosyada.
