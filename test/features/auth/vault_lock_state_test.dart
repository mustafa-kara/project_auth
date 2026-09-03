/// `VaultLockState`'in recovery key sızdırmayan `toString()` sözleşmesi
/// (güvenlik denetimi P2-3). `test/core/otp/otp_account_test.dart`'ın aynadaki
/// karşılığı — orada TOTP tohumu, burada 24 kelimelik recovery key söz konusu.
///
/// Equatable'ın `stringify` alanı assert'ler açıkken (debug/test) varsayılan
/// olarak AÇIKtır ve tüm `props`'u basar — `mnemonic` dahil. Testler, widget
/// ağacı dökümleri ve assertion mesajları debug modda çalıştığı için bu, master
/// key EŞDEĞERİ ve KALICI bir sırrı CI log'una düşürürdü.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';

void main() {
  // Gerçek bir BIP-39 listesi gerekmiyor; ayırt edilebilir olması yeterli.
  final words = List.generate(24, (i) => 'gizlikelime$i');

  VaultLockState pending() => VaultLockState.setupPending(mnemonic: words);

  void expectNoWords(String rendered) {
    for (final w in words) {
      expect(
        rendered,
        isNot(contains(w)),
        reason: 'recovery key kelimesi "$w" toString çıktısına sızdı',
      );
    }
  }

  test('toString() recovery key kelimelerini BASMAZ', () {
    expectNoWords(pending().toString());
  });

  test('toString() bir liste/koleksiyon içinde de BASMAZ', () {
    // State bir koleksiyona girip interpolasyona uğrarsa her eleman toString'e düşer.
    expectNoWords('${[pending(), pending()]}');
  });

  test('interpolasyon (\$state) da BASMAZ', () {
    final state = pending();
    expectNoWords('kilit durumu: $state');
  });

  test(
    'eşitlik ve hashCode DEĞİŞMEZ (stringify yalnız toString\'i etkiler)',
    () {
      expect(pending(), pending());
      expect(pending().hashCode, pending().hashCode);
      expect(
        pending(),
        isNot(VaultLockState.setupPending(mnemonic: const ['baska'])),
      );
      expect(
        const VaultLockState.locked(),
        isNot(const VaultLockState.unlocked()),
      );
    },
  );
}
