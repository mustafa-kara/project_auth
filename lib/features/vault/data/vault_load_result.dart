/// `VaultRepository.load()` sonucu: yüklenen hesaplar + atlanan bozuk kayıt sayısı.
///
/// `corruptedCount` side-channel (stale/race-prone) yerine doğrudan load
/// sonucunda taşınır (review). `VaultCubit` bunu state'e yazar, UI banner gösterir.
library;

import 'package:equatable/equatable.dart';

import '../../../core/otp/otp_account.dart';

class VaultLoadResult extends Equatable {
  final List<OtpAccount> accounts;

  /// Çözülemeyen / decode edilemeyen kayıt sayısı (kısmi bozulma). 0 = temiz.
  final int corruptedCount;

  const VaultLoadResult({required this.accounts, this.corruptedCount = 0});

  static const empty = VaultLoadResult(accounts: []);

  @override
  List<Object?> get props => [accounts, corruptedCount];
}
