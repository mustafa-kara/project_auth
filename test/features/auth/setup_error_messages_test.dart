/// `setupErrorMessage` — kurulum hatalarının kullanıcıya SABİT dizgelerle
/// gösterilmesi (güvenlik denetimi P3-6).
///
/// Eskiden `setup_password_page` ve `recovery_verify_page` ekrana ham `$e`
/// basıyordu; uygulamada bir istisnanın `toString`'inin filtresiz olarak UI'a
/// ulaştığı TEK yer orasıydı. Bu test, hangi tip gelirse gelsin çıktının önceden
/// yazılmış bir metin olduğunu ve istisnanın kendi `toString`'inden hiçbir
/// parçanın sızmadığını pinler (`import_page.dart`'ın `importErrorMessage`
/// deseniyle aynı sözleşme).
library;

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/crypto_exceptions.dart';
import 'package:project_auth/features/auth/presentation/setup_error_messages.dart';

void main() {
  test('zayıf parola → politika mesajı (KeyManager tek kaynağı)', () {
    expect(
      setupErrorMessage(const WeakPasswordException('Parola boş olamaz')),
      'Parola boş olamaz',
    );
  });

  test('PlatformException → sabit metin, platform detayı SIZMAZ', () {
    final e = PlatformException(
      code: 'Keystore',
      message: 'AndroidKeyStore alias=vault_gizli_detay',
      details: '/data/user/0/app/shared_prefs/FlutterSecureStorage.xml',
    );
    final text = setupErrorMessage(e);
    expect(text, contains('güvenli deposuna yazılamadı'));
    expect(text, isNot(contains('Keystore')));
    expect(text, isNot(contains('vault_gizli_detay')));
    expect(text, isNot(contains('shared_prefs')));
  });

  test('VaultIntegrityException → sabit metin, mesaj gövdesi SIZMAZ', () {
    const e = VaultIntegrityException('12 kayıt çözülemedi (iç detay)');
    final text = setupErrorMessage(e);
    expect(text, contains('okunamadı'));
    expect(text, isNot(contains('iç detay')));
  });

  test('bilinmeyen tip → jenerik metin, toString\'i EKLEMEZ', () {
    final e = StateError('commitSetup: setupPending değil — dahili ayrıntı');
    final text = setupErrorMessage(e);
    expect(text, 'Kurulum tamamlanamadı — tekrar dene.');
    expect(text, isNot(contains('setupPending')));
    expect(text, isNot(contains('dahili ayrıntı')));
  });

  test('hiçbir eşleme ham `toString` interpolasyonu yapmaz', () {
    final errors = <Object>[
      const WeakPasswordException('politika'),
      PlatformException(code: 'X-KOD-X'),
      const VaultIntegrityException('X-KOD-X'),
      Exception('X-KOD-X'),
      StateError('X-KOD-X'),
    ];
    for (final e in errors) {
      // WeakPasswordException KASITLI istisnadır: mesajı zaten kullanıcıya
      // yazılmış sabit bir politika metnidir (bkz. KeyManager.enforcePolicy).
      if (e is WeakPasswordException) continue;
      expect(
        setupErrorMessage(e),
        isNot(contains('X-KOD-X')),
        reason: '${e.runtimeType} için ham istisna içeriği ekrana sızıyor',
      );
    }
  });
}
