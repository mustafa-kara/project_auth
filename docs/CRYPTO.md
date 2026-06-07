# Kripto Tasarımı — E2E Vault (Faz 2)

> Kapsam (Patch 1–5 uygulandı): paket kararı, primitifler, anahtar hiyerarşisi,
> AAD şeması, BIP39 recovery, parola/normalization kararı, validasyon sınırları,
> şifreli vault deposu + migration; **Patch 4: setup/unlock/recovery UI + oturum
> kilidi (`VaultLockCubit`, lifecycle lock) + `KeyAttributesStore` + reset + UI
> redesign** (tasarım tarafı: [Design.md](Design.md)); **Patch 5: biyometrik unlock
> kısayolu (3. wrap + OS-keystore erişim kontrolü)** — bkz. §11.

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
biometricKey (32-byte rastgele, OS-gated) ─────wrap──▶ biometricEncryptedMasterKey  (Patch 5, opsiyonel)
```

- Parola **veya** recovery key **veya** (etkinse) biyometri, masterKey'i açar — üçü de
  aynı masterKey'i sarmalar. Biyometri yalnız bir *kısayol*; parola+recovery her zaman çalışır.
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
| masterKey ← biometricKey (Patch 5) | `masterkey-biometric\|1` |
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
- **Biyometri (Patch 5):** `KeyManager.enrollBiometric`/`biometricUnlock` round-trip
  integration_test'te (gerçek wrap/unwrap). `VaultLockCubit` biyometri akışları
  (enable/disable atomikliği, retrieve hata yolları, lifecycle inactive-vs-paused)
  `FakeBiometricService` ile host'ta. `BiometricServiceImpl` (gerçek `local_auth` +
  OS-keystore) GERÇEK cihaz ister → CI'da koşmaz; manuel doğrulama checklist'i §11.

## 11. Biyometrik unlock (Patch 5)

**Amaç:** parola yerine biyometri kısayolu — E2E modeli ZAYIFLATMADAN. masterKey her
zaman parola+recovery ile de açılır; biyometri yalnız 3. bir wrap yolu açar.

**Güvenlik sınırı = OS keystore erişim kontrolü** (`local_auth` bool'u DEĞİL):
- `biometricKey` (32-byte rastgele) `masterKey`'i `masterkey-biometric|1` AAD'siyle sarar
  → `biometricEncryptedMasterKey` (`KeyAttributes.bmk`, opsiyonel alan).
- `biometricKey`'in HAM byte'ları `flutter_secure_storage`'da **ayrı options'lı/namespace'li**
  (`vault_biometric_key_v1`) saklanır, **biyometrik erişim kontrolüyle**:
  - **iOS:** `useSecureEnclave: true` + `AccessControlFlag.biometryCurrentSet`
    (`KeychainAccessibility.passcode`). **`biometryCurrentSet` → biyometri seti değişince
    (yeni parmak/yüz eklenir veya silinir) anahtar OTOMATİK geçersizleşir** → kullanıcı bir
    kez parolayla açıp Settings'ten yeniden enroll eder (token kaybı YOK). Çalınan cihaza
    saldırgan kendi biyometrisini eklese bile eski anahtar geçersiz.
  - **Android:** `AndroidOptions.biometric(enforceBiometrics: true,
    biometricType: strongBiometricOnly)` → Keystore AES anahtarı
    `setUserAuthenticationRequired` ile **yalnız güçlü biyometriye** bağlı (PIN/pattern
    reddedilir). `strongBiometricOnly` → `biometricPromptNegativeButton` zorunlu. API 28+.
- **GERÇEK prompt** unlock'ta `storage.read()` OS geçidinden gelir (TEK prompt; `local_auth`
  yalnız availability kontrolü → çift prompt yok). `biometricKey` byte'ları Dart'ta ASLA
  cache'lenmez — her unlock geçitten yeniden okunur, kullanımdan sonra `fillRange(0)`.

**Tehdit modeli:** çalınan-kilitli cihaz → geçit açılmaz; rooted → anahtar TEE/Keystore'da
non-exportable (bool spoof'u işe yaramaz, zaten bool'a güvenmiyoruz); backup → `bmk` ciphertext'i
yedeklense bile sarma anahtarı yedeklenemez (Secure Enclave / userAuthenticationRequired).

**Availability (Android strong + SDK):** Dart'ta `flutter_secure_storage` native
strong-availability'sine erişim yok → `local_auth.getAvailableBiometrics().contains(strong)`
+ `device_info_plus` `sdkInt >= 28`. iOS'ta Face/Touch ID zaten strong.

**Lifecycle:** biyometri sistem prompt'u kısa süre `inactive` üretebilir; `_biometricPromptInFlight`
true iken `inactive` abort'tan muaf (başarılı unlock kesilmez), `paused` (gerçek arka plan)
yine kesin abort. `_abortToBackground` + ownership `unlock()` ile birebir aynı.

**Reset/disable:** `bmk` OS anahtarı ayrı namespace'te → `resetVault` + `disableBiometric`
açıkça `BiometricService.disable()` çağırır (default `_deleteKeys` yetmez).

**Manuel cihaz doğrulama checklist'i** (CI'da koşmaz):
1. Settings'ten enable → app kill → UnlockPage'de biyometri butonu → başarılı unlock.
2. Biyometri seti değiştir (yeni parmak ekle) → biyometri başarısız (`KeyMissing`) → parolaya düş,
   `bmk` temizlenir → Settings'ten yeniden enroll.
3. Lockout (çok deneme) → parolaya düş. App<28 (Android) → buton hiç görünmez.
