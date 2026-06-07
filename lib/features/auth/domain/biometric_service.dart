/// Biyometrik kilit açma servisi (Patch 5) — OS köprüsü soyutlaması.
///
/// **Güvenlik sınırı: GERÇEK geçit `retrieve()` içindeki OS-keystore erişim
/// kontrollü `storage.read()`'tir** (Secure Enclave / strong-biometric Keystore).
/// `local_auth` YALNIZ availability/enrollment kontrolü için kullanılır — unlock
/// sırasında prompt tetiklemez (çift prompt önlenir). Bir bool'a güvenilmez.
///
/// Interface → test edilebilirlik (cubit FakeBiometricService ile test edilir;
/// gerçek impl cihaz ister).
library;

import 'dart:typed_data';

abstract interface class BiometricService {
  /// Cihazda güçlü (strong) biyometri kullanılabilir mi: donanım + enrolled +
  /// destekli + (Android) API >= 28. Enrollment'tan (bizim `bmk`) BAĞIMSIZ —
  /// cihaz yeteneğini söyler.
  Future<bool> isAvailable();

  /// [keyBytes]'ı OS keystore'a biyometrik erişim kontrolüyle yazar. Çağıran,
  /// bu çağrıdan SONRA kendi [keyBytes] kopyasını zero-fill etmelidir.
  /// Var olan enrollment'ı üzerine yazar.
  Future<void> enroll(Uint8List keyBytes);

  /// OS biyometri prompt'unu tetikler + anahtarı okur (= GERÇEK GEÇİT). Taze
  /// `Uint8List` döner (çağıran kullandıktan sonra zero-fill eder).
  /// Hatalar: [BiometricCanceled] / [BiometricLockout] / [BiometricKeyMissing] /
  /// [BiometricUnavailable] / [BiometricStorageError].
  Future<Uint8List> retrieve();

  /// OS keystore'daki biyometrik anahtarı siler (biyometriyi kapat). Idempotent.
  Future<void> disable();
}
