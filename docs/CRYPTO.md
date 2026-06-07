# Kripto Tasarımı — E2E Vault (Faz 2)

> Kapsam (Patch 1–4 uygulandı): paket kararı, primitifler, anahtar hiyerarşisi,
> AAD şeması, BIP39 recovery, parola/normalization kararı, validasyon sınırları,
> şifreli vault deposu + migration; **Patch 4: setup/unlock/recovery UI + oturum
> kilidi (`VaultLockCubit`, lifecycle lock) + `KeyAttributesStore` + reset + UI
> redesign** (tasarım tarafı: [Design.md](Design.md)). Patch 5 (biyometri) ertelendi.

## 1. Paket kararı — `sodium 3.4.6` + `sodium_libs 3.4.6+4`

- **Neden 4.x değil:** `sodium 4.x` Dart SDK `^3.11.0` ister. Proje Dart `3.10.7`
  (Flutter 3.38.6 stable) → 4.x **çözülemez** (`flutter pub get` reddeder).
- **`sodium_libs` "discontinued" mı?** pub.dev etiketi öyle diyor; ama paket
  pre-built libsodium binary'lerini yükler, **native-assets / `--enable-experiment`
  flag GEREKTİRMEZ** ve 3.x hattı stable Flutter'da sorunsuz çalışır
  (`integration_test/` ile kanıtlı). Bu yüzden 3.x bilinçli ve doğru karardır.
- **İleride:** Flutter Dart 3.11+'a yükselince `sodium 4.x` native-assets'e geçiş
  ayrı, küçük bir migration olur (yalnız init satırı + import değişir; algoritma aynı).
- **Init:** `SodiumSumoInit.init()` → `SodiumSumo` (`pwhash` = Argon2id yalnız
  *sumo* yapısında bulunur).

## 2. Primitifler

| Amaç | Algoritma | sodium API |
|------|-----------|------------|
| KDF (parola → KEK) | **Argon2id** (moderate ops/mem) | `crypto.pwhash(alg: argon2id13)` |
| AEAD (veri + anahtar sarmalama) | **XChaCha20-Poly1305 IETF** | `crypto.aeadXChaCha20Poly1305IETF` |
| Rastgelelik | libsodium CSPRNG | `randombytes.buf`, `secureRandom` |

- `crypto_secretbox` **KULLANILMAZ** (AAD desteği + nonce-misuse direnci için IETF AEAD).
- Nonce her şifrelemede **rastgele** (`randombytes.buf(nonceBytes)`); XChaCha 24-byte
  nonce → rastgele güvenli, ciphertext yanında saklanır.
- **Argon2id ayrı isolate'ta zorunlu** (`runIsolated`): pwhash saniyeler sürer, UI'ı
  bloklar. Parola isolate içinde `Int8List`'e çevrilir, işlem sonrası zero-fill edilir.

## 3. Anahtar hiyerarşisi (Ente modeli)

```
masterKey  : 32-byte rastgele — ASIL veri anahtarı (token'ları şifreler)
             ↑ ASLA düz diske yazılmaz; yalnız oturum içinde bellekte (KeyHandle)

masterPassword ──Argon2id(salt,ops,mem)──▶ KEK ──wrap──▶ encryptedMasterKey
recoveryKey (32-byte rastgele, BIP39) ─────────wrap──▶ recoveryEncryptedMasterKey
```

- Parola **veya** recovery key, masterKey'i açar (ikisi de aynı masterKey'i sarmalar).
- **Parola değişimi** masterKey'i değiştirmez → token ciphertext'leri yeniden
  şifrelenmez; yalnız yeni salt + yeni KEK + yeni `encryptedMasterKey` yazılır.
  `recoveryEncryptedMasterKey` dokunulmaz.
- `KeyHandle` opaque wrapper → sodium `SecureKey` tipi domain/public API'ye sızmaz.
  Ham anahtar byte'ı yalnız wrap/unwrap helper'ları içinde, hemen `fillRange(0)` ile.

## 4. AAD (Additional Authenticated Data) şeması

AEAD'in additionalData alanı bağlamı kriptografik olarak bağlar → bir blob başka
bağlamda çözülemez (örn. masterKey-wrap blob'u token olarak açılamaz).

| Bağlam | AAD (UTF-8/codeUnits) |
|--------|------------------------|
| masterKey ← KEK | `masterkey-kek\|1` |
| masterKey ← recovery key | `masterkey-recovery\|1` |
| Token kaydı (Patch 3) | `token\|1\|<id>` |

## 5. Recovery key — kendi BIP-39 implementasyonumuz

- Kanonik `bip39` paketi yıllardır bakımsız/unverified → **güven sınırına sokulmaz**.
  Kendi `encode`/`decode`'umuzu yazdık (yalnız kodlama + checksum; kripto rutini değil).
- 256-bit entropy → SHA-256 ilk byte (8-bit checksum) → 24 × 11-bit → kelime.
- **Wordlist:** resmi BIP-0039 İngilizce 2048 kelime (bitcoin/bips, `english.txt`).
  SHA-256 `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`.
  **Lisans: MIT** (BIP-0039 "This BIP falls under the MIT License"; bitcoin/bips kök
  LICENSE MIT — 2026-06-07 teyit edildi). `bip39_wordlist.dart` başında attribution.
- `decode` checksum doğrular → yazım hatası / yanlış kelime yakalanır
  (`FormatException`). Resmi Trezor 256-bit test vektörleriyle doğrulandı.

## 6. Parola normalization kararı

- Dart core'da **NFKC normalizer YOK** → ekstra bağımlılık eklememek için
  **normalization YAPILMAZ; parola birebir UTF-8 byte'ı olarak hash'lenir**.
- Sonuç: parola tam girildiği gibi kullanılır (yaygın, güvenli tercih).
- İleride Unicode parola UX'i istenirse normalize-on-input ayrı ele alınır.

## 7. Domain parola politikası

`KeyManager` bir güvenlik sınırı olduğu için UI validator'ına ek olarak minimum
kural burada da zorlanır (`WeakPasswordException`):
- trim sonrası boş → red
- `< KeyManager.minPasswordLength` (8) → red
- Politika kontrolü trim'lenir ama **gerçek KEK türetiminde parola birebir** kullanılır.

## 8. Metadata/blob sıkı validasyonu (bozuk/ileri şema erken yakalama)

Bozuk veya ileri-sürüm metadata, sodium'a ulaşmadan **erkenden** reddedilir —
yoksa geç sodium hatası "yanlış parola" gibi görünür veya ileri şema yanlış
yorumlanır (`FormatException`):

| Alan | Kural |
|------|-------|
| `EncryptedBlob.version` | `1..supportedVersion` |
| `EncryptedBlob` nonce | tam `24` byte (XChaCha IETF) |
| `EncryptedBlob` ciphertext | en az `16` byte (Poly1305 tag) |
| `KeyAttributes.version` | `1..supportedVersion` |
| `KeyAttributes.kdfSalt` | tam `16` byte (`crypto_pwhash_SALTBYTES`) |
| `KeyAttributes.kdfOps/kdfMem` | pozitif tamsayı (kesirli `num` reddedilir) |

JSON parse `as` cast kullanmaz; tip-güvenli yardımcılarla (`_asString/_asInt/_asMap`)
yanlış tip → `FormatException`. Kesirli `num` (örn. `ops: 1.5`) sessizce truncate
edilmez; tamsayı-değerli double (`3.0`) kabul edilir.

## 9. Şifreli vault deposu + migration (Patch 3)

**`EncryptedVaultRepository`** (`vault_encrypted_v1`) — token-bazlı şifreli kayıt:
```
{ id, v, n(nonce b64), c(ciphertext b64), updatedAt(epoch ms), deleted }
```
- plaintext = `OtpAccount.toJson()` → UTF-8 → `encrypt(aad: token|1|<id>)`.
- `deleted` Faz 2'de hep `false` (soft-delete Faz 3 API genişlemesi gerektirir —
  `save(List)` replace semantiği tombstone üretemez).
- **Unchanged-blob koruması:** `save()` yalnız içeriği değişen/yeni kaydı yeniden
  şifreler (`OtpAccount` Equatable karşılaştırması); değişmeyen eski blob'u +
  `updatedAt`'i korur. HOTP counter artışında tüm vault re-encrypt edilmez.
- **Bozuk kayıt koruması:** decode/decrypt edilemeyen ham kayıtlar bellekte
  tutulur ve `save()`'te AYNEN geri yazılır (map değil scalar/null bile → cast yok,
  verbatim). Kullanıcı banner'a rağmen token eklese bile bozuk kayıt düşmez.
- **Sessiz veri kaybı yok:** top-level malformed/non-list VEYA tüm kayıt decrypt
  fail → `VaultIntegrityException` (boş vault gösterilmez). Kısmi → `corruptedCount`.
- **Integrity state'inde mutasyon reddi (onaysız overwrite koruması):**
  `VaultIntegrityException` atıldığında `load()` ERKEN çıkar → repo cache
  (`_lastById`/`_corruptedRaw`) BOŞ kalır. Bu state'te bir `save()` çalışırsa,
  cache boş olduğu için diskteki bozuk-ama-belki-kurtarılabilir ham vault yalnız
  yeni içerikle EZİLİR (kullanıcının açık "Vault'u sıfırla" onayı olmadan). Bu
  yüzden mutasyon **state-makinesi seviyesinde reddedilir:** `VaultCubit`
  `state.error != null` iken `add`/`removeById`/`incrementCounter` çağrılırsa
  `StateError` fırlatır (UI yakalar → SnackBar; sessiz no-op değil). Ek savunma
  katmanı: `VaultPage` integrity ekranında ekleme FAB'ını gizler. (Genel ilke:
  "depo cache'i load'da dolar" varsayan her yazma yolu, load'ın erken fırladığı
  state'lerde de güvenli olmalı — UI gizleme tek başına yeterli değil, UI atlanabilir.)
- `purgeCorrupted()` yalnız açık kullanıcı onayıyla bozuk kayıtları siler;
  sağlam + değişmemiş blob'lara dokunmaz.

**`VaultMigration`** (Faz 1 plaintext → şifreli, tek seferlik):
- Ayrı **commit marker** `vault_migration_v1="committed"` (idempotency; "encrypted
  var diye no-op" tuzağına düşmez).
- Akış: marker committed → no-op · plaintext yok → marker yaz · plaintext var →
  **mevcut encrypted'i oku + id-bazlı MERGE** (mevcut şifreli kazanır, eksik
  plaintext eklenir) → save → geri oku + doğrula → plaintext sil → marker yaz.
- Crash-güvenli: yarım migration'da (marker yok + plaintext var + encrypted'te
  başka kayıt) tekrar çalışır, **upsert** sayesinde var olanı ezmez + duplicate yok.
  load integrity hatası atarsa destructive adım atmaz (plaintext silme/marker yok).

## 10. Test stratejisi

- **Saf-Dart (`test/`, plain `flutter test`):** `EncryptedBlob`, `KeyAttributes`
  JSON+validasyon, `Bip39` (libsodium gerektirmez).
- **Integration (`integration_test/`, cihaz/simülatör):** `SodiumCryptoService`,
  `KeyManager`, `EncryptedVaultRepository`/`VaultMigration` — gerçek libsodium
  gerekir; `sodium_libs` platform plugin'i plain `flutter test` VM host'unda
  yüklenmez (`SodiumPlatform.instance` hatası). In-memory `FakeSecureStorage`
  Keychain'e dokunmadan storage davranışını sadık modeller.
