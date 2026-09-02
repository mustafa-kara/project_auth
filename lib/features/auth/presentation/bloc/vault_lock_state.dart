/// [VaultLockCubit] durum modeli. Router redirect guard'ı `status`'a göre çalışır.
library;

import 'package:equatable/equatable.dart';

enum VaultLockStatus {
  uninitialized,
  setupPending,
  locked,
  unlocked,
  locking,
  keyAttributesCorrupted,

  /// Faz 3 Patch 2: lokal attrs yok + sunucudan `key_attributes` ÇEKİLİYOR.
  /// Geçici. Router `/splash`'e tutar — **ASLA `/setup`'a değil** (fetch bitmeden
  /// kullanıcı yeni vault kuramaz → "yalnız gerçek 0-row'da setup" garantisi).
  restoring,

  /// Faz 3 Patch 2: sunucudan çekme AĞ/RLS hatası verdi (gerçek 0-row DEĞİL).
  /// Ayrı `/auth/restore-failed` ekranı (tekrar dene / hesap değiştir). `uninitialized`'a
  /// DÜŞÜLMEZ → kullanıcı yanlış parola kurup sunucudaki vault'u çakıştıramaz.
  restoreFailed,
}

/// Unlock/recover ekranlarında gösterilen inline hata sebebi.
enum VaultLockError {
  wrongPassword,
  wrongRecovery,
  weakPassword,
  biometricFailed,
  biometricLockout,
}

class VaultLockState extends Equatable {
  final VaultLockStatus status;

  /// Yalnız `setupPending` iken dolu — recovery key (24 kelime) gösterimi/doğrulaması.
  final List<String> mnemonic;

  /// Yalnız `locked` iken dolu olabilir — son unlock/recover denemesi hatası.
  final VaultLockError? error;

  /// Bu cihazda biyometri enroll edilmiş mi (`attrs.bmk != null`). Patch 5.
  /// Settings switch'in AÇIK/KAPALI değeri = bu (enrolled durumu).
  final bool biometricEnrolled;

  /// Cihaz biyometri YETENEĞİ (donanım+enrolled+strong+API≥28), enrollment'tan
  /// BAĞIMSIZ. Settings enable switch'inin etkin olup olmadığını belirler. Patch 5.
  final bool deviceBiometricAvailable;

  const VaultLockState._(
    this.status, {
    this.mnemonic = const [],
    this.error,
    this.biometricEnrolled = false,
    this.deviceBiometricAvailable = false,
  });

  const VaultLockState.uninitialized() : this._(VaultLockStatus.uninitialized);

  const VaultLockState.setupPending({required List<String> mnemonic})
    : this._(VaultLockStatus.setupPending, mnemonic: mnemonic);

  const VaultLockState.locked({
    VaultLockError? error,
    bool biometricEnrolled = false,
    bool deviceBiometricAvailable = false,
  }) : this._(
         VaultLockStatus.locked,
         error: error,
         biometricEnrolled: biometricEnrolled,
         deviceBiometricAvailable: deviceBiometricAvailable,
       );

  const VaultLockState.unlocked({
    bool biometricEnrolled = false,
    bool deviceBiometricAvailable = false,
  }) : this._(
         VaultLockStatus.unlocked,
         biometricEnrolled: biometricEnrolled,
         deviceBiometricAvailable: deviceBiometricAvailable,
       );

  const VaultLockState.locking() : this._(VaultLockStatus.locking);

  const VaultLockState.keyAttributesCorrupted()
    : this._(VaultLockStatus.keyAttributesCorrupted);

  const VaultLockState.restoring() : this._(VaultLockStatus.restoring);

  const VaultLockState.restoreFailed() : this._(VaultLockStatus.restoreFailed);

  /// UnlockPage biyometri butonu görünürlüğü: enrolled VE cihaz uygun.
  bool get biometricUnlockAvailable =>
      biometricEnrolled && deviceBiometricAvailable;

  @override
  List<Object?> get props => [
    status,
    mnemonic,
    error,
    biometricEnrolled,
    deviceBiometricAvailable,
  ];
}
