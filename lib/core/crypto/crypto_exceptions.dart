/// Kripto/vault katmanı hata tipleri.
///
/// Faz 1'deki "bozuk kaydı sessizce atla" yalnızca *plaintext* repo içindi.
/// Şifreli vault'ta decrypt başarısızlığı tamper/yanlış-anahtar sinyalidir →
/// sessizce "boş vault" göstermek veri kaybını gizler. Bu yüzden ayrı,
/// anlamlı exception'lar.
library;

/// AEAD decrypt başarısız (yanlış anahtar / yanlış AAD / tamper).
class DecryptException implements Exception {
  final String message;
  const DecryptException([this.message = 'Şifre çözme başarısız']);
  @override
  String toString() => 'DecryptException: $message';
}

/// Master parola ile master key açılamadı (KEK yanlış).
class WrongPasswordException implements Exception {
  const WrongPasswordException();
  @override
  String toString() => 'WrongPasswordException: master parola hatalı';
}

/// Master parola domain politikasını (boş / çok kısa) karşılamıyor.
/// UI validator'ı ek koruma; ama `KeyManager` güvenlik sınırı olduğu için
/// minimum kuralı burada da zorlanır.
class WeakPasswordException implements Exception {
  final String message;
  const WeakPasswordException([this.message = 'Parola çok zayıf']);
  @override
  String toString() => 'WeakPasswordException: $message';
}

/// Recovery key (mnemonic) ile master key açılamadı.
class WrongRecoveryKeyException implements Exception {
  const WrongRecoveryKeyException();
  @override
  String toString() => 'WrongRecoveryKeyException: recovery key hatalı';
}

/// Şifreli vault'un bütünlüğü doğrulanamadı: top-level depolama bozuk
/// (malformed/non-list) VEYA kayıtların hiçbiri çözülemedi (yanlış masterKey/
/// toptan bozulma). "Boş vault" gibi davranılmaz — kullanıcıya açıkça bildirilir.
class VaultIntegrityException implements Exception {
  final String message;
  const VaultIntegrityException([
    this.message = 'Vault bütünlüğü doğrulanamadı',
  ]);
  @override
  String toString() => 'VaultIntegrityException: $message';
}
