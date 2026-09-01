/// `OtpAccount`'un secret sızdırmayan `toString()` sözleşmesi (review takibi).
///
/// Equatable'ın `stringify` alanı DEBUG derlemelerinde varsayılan olarak AÇIKtır
/// ve tüm `props`'u basar — `secret` dahil. Testler, widget ağacı dökümleri ve
/// assertion mesajları debug modda çalıştığı için bu, TOTP tohumunu CI log'una
/// düşürürdü. `stringify => false` bunu keser.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';

void main() {
  const secret = 'JBSWY3DPEHPK3PXP';

  OtpAccount account() => OtpAccount(
        id: 'tok-1',
        secret: secret,
        type: OtpType.totp,
        issuer: 'GitHub',
        accountName: 'alice@example.com',
      );

  test('toString() secret BASMAZ', () {
    expect(account().toString(), isNot(contains(secret)));
  });

  test('toString() bir liste/koleksiyon içinde de secret BASMAZ', () {
    // Bir hesap listesi interpolasyona girdiğinde her eleman toString()'e düşer.
    expect('${[account(), account()]}', isNot(contains(secret)));
  });

  test('eşitlik ve hashCode DEĞİŞMEZ (stringify yalnız toString\'i etkiler)',
      () {
    expect(account(), account());
    expect(account().hashCode, account().hashCode);
    expect(account(), isNot(account().copyWith(secret: 'GEZDGNBVGY3TQOJQ')));
  });
}
