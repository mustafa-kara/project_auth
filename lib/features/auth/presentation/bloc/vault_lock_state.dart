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
}

/// Unlock/recover ekranlarında gösterilen inline hata sebebi.
enum VaultLockError { wrongPassword, wrongRecovery, weakPassword }

class VaultLockState extends Equatable {
  final VaultLockStatus status;

  /// Yalnız `setupPending` iken dolu — recovery key (24 kelime) gösterimi/doğrulaması.
  final List<String> mnemonic;

  /// Yalnız `locked` iken dolu olabilir — son unlock/recover denemesi hatası.
  final VaultLockError? error;

  const VaultLockState._(this.status, {this.mnemonic = const [], this.error});

  const VaultLockState.uninitialized() : this._(VaultLockStatus.uninitialized);

  const VaultLockState.setupPending({required List<String> mnemonic})
      : this._(VaultLockStatus.setupPending, mnemonic: mnemonic);

  const VaultLockState.locked({VaultLockError? error})
      : this._(VaultLockStatus.locked, error: error);

  const VaultLockState.unlocked() : this._(VaultLockStatus.unlocked);

  const VaultLockState.locking() : this._(VaultLockStatus.locking);

  const VaultLockState.keyAttributesCorrupted()
      : this._(VaultLockStatus.keyAttributesCorrupted);

  @override
  List<Object?> get props => [status, mnemonic, error];
}
