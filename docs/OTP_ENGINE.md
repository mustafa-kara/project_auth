# OTP Çekirdeği (`lib/core/otp/`)

Sunucusuz, saf Dart OTP motoru. Ağ/IO yok; tüm fonksiyonlar deterministik ve
birim test edilebilir. Faz 1'in kalbidir ve Faz 2'de (E2E kripto) bu modelin
açık verisi `masterKey` ile şifrelenir.

## Dosyalar

| Dosya | Sorumluluk |
|---|---|
| `base32.dart` | RFC 4648 Base32 decode/encode (padding/boşluk/küçük harf toleranslı) |
| `otp_algorithm.dart` | `OtpAlgorithm` enum (SHA1/256/512) + `crypto.Hash` eşlemesi |
| `otp_generator.dart` | HOTP (RFC 4226), TOTP (RFC 6238), Steam Guard üretimi |
| `otp_account.dart` | `OtpAccount` değişmez model (Equatable) + `OtpType` |
| `otpauth_uri.dart` | `otpauth://` URI parse / serialize (Key URI Format) |

## Algoritmalar

- **HOTP (RFC 4226):** `HMAC(secret, counter_8byte_BE)` → dynamic truncation (§5.3)
  → `31-bit int % 10^digits`, soldan sıfır dolgulu.
- **TOTP (RFC 6238):** HOTP üzerine; `counter = floor(unixSeconds / period)`.
  SHA1/256/512 + değişken `digits`/`period` destekli.
- **Steam Guard:** TOTP sayacı + SHA1; digit yerine 26-harfli alfabeden
  (`23456789BCDFGHJKMNPQRTVWXY`) 5 sembol.
- **Geri sayım:** `secondsRemaining = period - (unixSeconds % period)` — UI halkası.

## `otpauth://` URI

`otpauth://TYPE/LABEL?secret=...&issuer=...&algorithm=...&digits=...&period=...&counter=...`

- `LABEL` = `issuer:account` veya yalnız `account` (URL-decode edilir).
- Query'deki `issuer`, label'daki issuer'ı geçersiz kılar (spec önceliği).
- Steam tespiti: `host=steam` **veya** (`host=totp` ve `issuer=Steam`).
- `secret` zorunlu; eksik/yanlış şema → `FormatException`.

### Input validasyonu (parse anında — UI crash önleme)
`parse()` tek giriş kapısıdır (hem QR hem manuel giriş). Malformed girişin geç bir aşamada
(kart render'ında) çökmesini önlemek için doğrulama **parse anında** yapılır:
- **secret** → Base32 decode edilir; geçersiz/boş → `FormatException` (yoksa `secretBytes`
  getter'ı kartta `FormatException` fırlatıp UI'ı çökertirdi).
- **digits** → 6–8 (Steam için ayrıca 5); dışı → `FormatException` (digits=0 anlamsız kod üretirdi).
- **period** → 1–600; `period=0` reddedilir (yoksa `secondsRemaining`/sayaçta sıfıra bölme).
- **counter** → ≥0; negatif reddedilir. **HOTP'te zorunludur** (Key URI Format) — eksikse
  `FormatException` (0 varsaymak yanlış sayaçla token ekletirdi). TOTP/Steam'de kullanılmaz, eksikse 0.
- **algorithm** → eksik/boş ise SHA1 (RFC default); verilmişse SHA1/SHA256/SHA512 (tire/harf
  toleranslı) kabul; **verilmiş ama desteklenmeyen** (typo, `SHA3`, `md5`) → `FormatException`
  (yoksa sessizce SHA1'e düşüp yanlış kod üretirdi).
- Eksik parametre → güvenli varsayılan; **verilmiş ama geçersiz** → reddedilir.

`features/vault` `_AddSheet` bu `FormatException`'ı yakalayıp kullanıcıya hata olarak gösterir.

## Doğruluk — RFC test vektörleri

`test/core/otp/` altında **54 test, hepsi geçiyor** (proje toplamı 60 = 54 OTP + 5 VaultCubit + 1 widget smoke; `flutter test`):

| Grup | Kaynak | Kapsam |
|---|---|---|
| HOTP | RFC 4226 Appendix D | counter 0–9, 6 hane (10 vektör) |
| TOTP | RFC 6238 Appendix B | SHA1/256/512, t=59 … 20000000000, 8 hane (10 vektör) |
| Sayaç/geri sayım | — | `totpCounter`, `secondsRemaining` |
| Steam | — | 5 karakter + alfabe doğrulaması |
| Base32 | RFC 4648 | bilinen vektör, tolerans, round-trip, hatalı giriş |
| URI | Key URI Format | parse varyantları + serialize→parse round-trip |
| URI validasyon | — | malformed secret/digits/period/counter/algorithm + HOTP eksik-counter → FormatException; geçerli algorithm + stabil id (16 test) |

> Test vektörleri RFC eklerinden alındı ve motor bunlara karşı **çalıştırılarak**
> doğrulandı (ezbere değil). Vektörler değişirse veya motor bozulursa testler kırılır.

## Önemli uygulama notları

- `crypto` paketi `as crypto` **prefix'iyle** import edilir: paketin top-level
  `sha1`/`sha256`/`sha512` sabitleri `OtpAlgorithm` enum değerleriyle isim çakışır.
- `OtpAccount` saf değer nesnesidir; `secretBytes` getter'ı Base32'yi decode eder.
- `OtpAccount` her örnek için stabil bir **uuid v4 `id`** taşır (verilmezse üretimde atanır).
  `id` lokal kimliktir, `otpauth://` URI'de **taşınmaz** (round-trip'te yeni id üretilir).
  Vault id-bazlı çalışır (`VaultCubit.removeById`/`incrementCounter(id)`, `OtpCard`
  `ValueKey(id)`) → liste değişiminde yanlış öğeye dokunulmaz; Faz 3 backfill için idempotent.
- Şu an vault **in-memory** (`VaultCubit`). Sonraki adımlar: `flutter_secure_storage`
  ile kalıcılık (şifresiz, OS koruması) → Faz 2'de `masterKey` ile E2E şifreleme.
