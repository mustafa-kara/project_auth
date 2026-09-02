/// Biyometrik unlock (Patch 5) hata tipleri.
///
/// `local_auth` + OS-keystore-gated `flutter_secure_storage` katmanından gelen
/// platform hatalarını domain seviyesine eşler. GERÇEK güvenlik geçidi
/// `storage.read()` OS access-control'üdür; bu exception'lar yalnız akış kontrolü
/// + kullanıcı geri bildirimi içindir. Hiçbiri parola+recovery yolunu etkilemez.
library;

/// Biyometri bu cihazda kullanılamaz: donanım yok / enrolled biyometri yok /
/// cihaz desteklemiyor / (Android) API < 28. Buton/switch gizlenir.
class BiometricUnavailable implements Exception {
  final String message;
  const BiometricUnavailable([this.message = 'Biyometri kullanılamıyor']);
  @override
  String toString() => 'BiometricUnavailable: $message';
}

/// Kullanıcı biyometri prompt'unu iptal etti / sistem iptal etti.
/// Sessizce parola alanına düşülür (vault kilitli kalır).
class BiometricCanceled implements Exception {
  const BiometricCanceled();
  @override
  String toString() => 'BiometricCanceled: kullanıcı iptal etti';
}

/// Çok fazla başarısız deneme → geçici/kalıcı biyometri kilidi.
/// Kullanıcı parola ile açmalı (ya da OS kilidini çözmeli).
class BiometricLockout implements Exception {
  const BiometricLockout();
  @override
  String toString() => 'BiometricLockout: biyometri kilitlendi';
}

/// OS keystore'da biyometrik anahtar (`vault_biometric_key_v1`) bulunamadı veya
/// geçersizleşti (biyometri seti değişti → `biometryCurrentSet`/`strongBiometricOnly`
/// invalidation). Enrollment kaybolmuş → `bmk` temizlenip parolaya düşülür.
class BiometricKeyMissing implements Exception {
  const BiometricKeyMissing();
  @override
  String toString() => 'BiometricKeyMissing: biyometrik anahtar yok/geçersiz';
}

/// OS-gated storage okuma/yazma sırasında beklenmeyen platform hatası
/// (`PlatformException`). Tanımlı bir kategoriye (cancel/lockout/keymissing)
/// girmeyen durumlar buraya düşer.
class BiometricStorageError implements Exception {
  final String message;
  const BiometricStorageError([this.message = 'Biyometrik depolama hatası']);
  @override
  String toString() => 'BiometricStorageError: $message';
}

/// biometricKey ile masterKey açılamadı (AEAD decrypt fail — bmk yok/bozuk/
/// yanlış biometricKey). Yanlış parolanın biyometri karşılığı.
class BiometricUnwrapException implements Exception {
  final String message;
  const BiometricUnwrapException([
    this.message = 'Biyometrik anahtar ile master key açılamadı',
  ]);
  @override
  String toString() => 'BiometricUnwrapException: $message';
}
