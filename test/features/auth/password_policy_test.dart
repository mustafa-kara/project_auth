/// Master parola politikası — saf fonksiyon birimleri (host'ta çalışır, sodium
/// gerekmez). Politika tek noktada `KeyManager`'da; `setup`/`changePassword` bunu
/// `_enforcePasswordPolicy` üzerinden uygular (round-trip kanıtı integration_test/).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/features/auth/domain/key_manager.dart';

void main() {
  group('passwordClassCount', () {
    test('boş → 0', () => expect(KeyManager.passwordClassCount(''), 0));
    test(
      'yalnız küçük harf → 1',
      () => expect(KeyManager.passwordClassCount('abcdef'), 1),
    );
    test(
      'küçük + büyük → 2',
      () => expect(KeyManager.passwordClassCount('abcDEF'), 2),
    );
    test(
      'küçük + büyük + rakam → 3',
      () => expect(KeyManager.passwordClassCount('abcDEF12'), 3),
    );
    test(
      'dört sınıf → 4',
      () => expect(KeyManager.passwordClassCount('abcDEF12!?'), 4),
    );
  });

  group('meetsPolicy (min ${KeyManager.minPasswordLength} kar, '
      '${KeyManager.minPasswordClasses} sınıf)', () {
    test(
      'kısa parola reddedilir',
      () => expect(KeyManager.meetsPolicy('Ab1!'), isFalse),
    );
    test(
      'yeterli uzun ama tek sınıf reddedilir',
      () => expect(KeyManager.meetsPolicy('parolaparola'), isFalse),
    );
    test(
      'yeterli uzun ama iki sınıf reddedilir',
      () => expect(KeyManager.meetsPolicy('parolaParola'), isFalse),
    );
    test(
      '12 kar + 3 sınıf kabul edilir',
      () => expect(KeyManager.meetsPolicy('Parola123abc'), isTrue),
    );
    test(
      'uzun + 4 sınıf kabul edilir',
      () => expect(KeyManager.meetsPolicy('Parola123!demo'), isTrue),
    );
    test(
      'tam sınırda (12 kar, 3 sınıf) kabul edilir',
      () => expect(KeyManager.meetsPolicy('Abcdefghij12'), isTrue),
    );
  });
}
