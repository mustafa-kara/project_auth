/// KeyManager integration testleri (cihaz/simülatör — gerçek libsodium + Argon2id).
///
/// `flutter test integration_test/key_manager_test.dart -d <device>`
/// masterKey eşitliği `extractKeyBytes` ile DEĞİL (public API'de yok),
/// **fonksiyonel round-trip** ile kanıtlanır: setup masterKey'i ile şifrelenen
/// bir token, unlock/recover'dan dönen masterKey ile çözülebiliyorsa eşittir.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:project_auth/core/crypto/crypto_exceptions.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/core/crypto/key_handle.dart';
import 'package:project_auth/core/crypto/sodium_crypto_service.dart';
import 'package:project_auth/features/auth/domain/biometric_exceptions.dart';
import 'package:project_auth/features/auth/domain/key_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late SodiumCryptoService crypto;
  late KeyManager km;

  setUpAll(() async {
    crypto = SodiumCryptoService();
    await crypto.init();
    km = KeyManager(crypto);
  });

  Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));
  final tokenAad = bytes('token|1|t1');

  /// masterKey ile bir "token" şifreler — kimlik (eşitlik) testi için referans.
  EncryptedBlob sealToken(KeyHandle masterKey, String plain) =>
      crypto.encrypt(plaintext: bytes(plain), key: masterKey, aad: tokenAad);

  /// Verilen masterKey ile token açılabiliyor mu (eşitlik kanıtı).
  bool canOpen(KeyHandle masterKey, EncryptedBlob token, String expected) {
    final out = crypto.decrypt(blob: token, key: masterKey, aad: tokenAad);
    return utf8.decode(out) == expected;
  }

  test('setup → unlock round-trip: aynı masterKey', () async {
    final s = await km.setup('Parola123!demo');
    expect(s.recoveryMnemonic.length, 24);
    final token = sealToken(s.masterKey, 'SEED-DATA');

    final unlocked = await km.unlock(s.attrs, 'Parola123!demo');
    expect(canOpen(unlocked, token, 'SEED-DATA'), isTrue);

    s.masterKey.dispose();
    unlocked.dispose();
  });

  test('yanlış parola → WrongPasswordException', () async {
    final s = await km.setup('Dogru-Parola12');
    await expectLater(
      km.unlock(s.attrs, 'yanlis-parola'),
      throwsA(isA<WrongPasswordException>()),
    );
    s.masterKey.dispose();
  });

  test('setup → recoverUnlock round-trip: aynı masterKey', () async {
    final s = await km.setup('Parola123!demo');
    final token = sealToken(s.masterKey, 'SEED-DATA');

    final recovered = await km.recoverUnlock(s.attrs, s.recoveryMnemonic);
    expect(canOpen(recovered, token, 'SEED-DATA'), isTrue);

    s.masterKey.dispose();
    recovered.dispose();
  });

  test('yanlış mnemonic → WrongRecoveryKeyException', () async {
    final s = await km.setup('Parola123!demo');
    // geçerli kelimeler ama yanlış kombinasyon (checksum tutarsa bile masterKey açılmaz)
    final wrong = List<String>.from(s.recoveryMnemonic);
    wrong[0] = wrong[0] == 'abandon' ? 'ability' : 'abandon';
    await expectLater(
      km.recoverUnlock(s.attrs, wrong),
      throwsA(isA<WrongRecoveryKeyException>()),
    );
    s.masterKey.dispose();
  });

  test('bozuk mnemonic (checksum) → WrongRecoveryKeyException', () async {
    final s = await km.setup('Parola123!demo');
    final corrupt = List<String>.from(s.recoveryMnemonic)..[23] = 'zoo';
    await expectLater(
      km.recoverUnlock(s.attrs, corrupt),
      throwsA(isA<WrongRecoveryKeyException>()),
    );
    s.masterKey.dispose();
  });

  test('changePassword: yeni parola açar, eski açmaz, masterKey AYNI', () async {
    final s = await km.setup('Eski-Parola12');
    final token = sealToken(s.masterKey, 'SEED-DATA');

    final newAttrs = await km.changePassword(s.attrs, s.masterKey, 'Yeni-Parola123');

    // Yeni parola ile unlock → aynı masterKey (eski token hâlâ açılır)
    final unlocked = await km.unlock(newAttrs, 'Yeni-Parola123');
    expect(canOpen(unlocked, token, 'SEED-DATA'), isTrue,
        reason: 'masterKey değişmedi → eski ciphertext açılmalı');

    // Eski parola artık açmaz
    await expectLater(
      km.unlock(newAttrs, 'Eski-Parola12'),
      throwsA(isA<WrongPasswordException>()),
    );

    // recovery hâlâ çalışır (recoveryEncryptedMasterKey dokunulmadı)
    final recovered = await km.recoverUnlock(newAttrs, s.recoveryMnemonic);
    expect(canOpen(recovered, token, 'SEED-DATA'), isTrue);

    s.masterKey.dispose();
    unlocked.dispose();
    recovered.dispose();
  });

  test('changePassword salt/encryptedMasterKey birlikte güncellenir', () async {
    final s = await km.setup('Ilk-Parola123');
    final newAttrs = await km.changePassword(s.attrs, s.masterKey, 'Ikinci-Parola12');
    // salt değişmeli
    expect(newAttrs.kdfSalt, isNot(s.attrs.kdfSalt));
    // encryptedMasterKey değişmeli (yeni KEK ile sarmalandı)
    expect(newAttrs.encryptedMasterKey.ciphertext,
        isNot(s.attrs.encryptedMasterKey.ciphertext));
    // recovery DOKUNULMAZ
    expect(newAttrs.recoveryEncryptedMasterKey.ciphertext,
        s.attrs.recoveryEncryptedMasterKey.ciphertext);
    s.masterKey.dispose();
  });

  test('zayif/bos parola domainde reddedilir -> WeakPasswordException', () async {
    await expectLater(km.setup(''), throwsA(isA<WeakPasswordException>()));
    await expectLater(km.setup('   '), throwsA(isA<WeakPasswordException>()));
    await expectLater(km.setup('kisa'), throwsA(isA<WeakPasswordException>()));
    // 12+ karakter AMA tek sınıf (yalnız küçük harf) → kompozisyon kuralı reddeder
    await expectLater(
        km.setup('parolaparola'), throwsA(isA<WeakPasswordException>()));

    // changePassword da aynı politikayı uygular
    final s = await km.setup('Gecerli-Parola12');
    await expectLater(
      km.changePassword(s.attrs, s.masterKey, 'x'),
      throwsA(isA<WeakPasswordException>()),
    );
    s.masterKey.dispose();
  });

  // --- Biyometri (Patch 5) ---

  test('enrollBiometric → biometricUnlock round-trip: aynı masterKey', () async {
    final s = await km.setup('Parola123!demo');
    final token = sealToken(s.masterKey, 'SEED-DATA');

    final enroll = km.enrollBiometric(s.attrs, s.masterKey);
    expect(enroll.biometricKeyBytes.length, 32);
    expect(enroll.attrs.biometricEncryptedMasterKey, isNotNull);

    final unlocked = km.biometricUnlock(enroll.attrs, enroll.biometricKeyBytes);
    expect(canOpen(unlocked, token, 'SEED-DATA'), isTrue);

    enroll.biometricKeyBytes.fillRange(0, enroll.biometricKeyBytes.length, 0);
    s.masterKey.dispose();
    unlocked.dispose();
  });

  test('biometricUnlock bmk yok attrs → BiometricUnwrapException', () async {
    final s = await km.setup('Parola123!demo');
    final dummyKey = crypto.randomBytes(32);
    expect(
      () => km.biometricUnlock(s.attrs, dummyKey),
      throwsA(isA<BiometricUnwrapException>()),
    );
    dummyKey.fillRange(0, dummyKey.length, 0);
    s.masterKey.dispose();
  });

  test('yanlış biometricKey → BiometricUnwrapException', () async {
    final s = await km.setup('Parola123!demo');
    final enroll = km.enrollBiometric(s.attrs, s.masterKey);
    final wrongKey = crypto.randomBytes(32);
    expect(
      () => km.biometricUnlock(enroll.attrs, wrongKey),
      throwsA(isA<BiometricUnwrapException>()),
    );
    wrongKey.fillRange(0, wrongKey.length, 0);
    enroll.biometricKeyBytes.fillRange(0, enroll.biometricKeyBytes.length, 0);
    s.masterKey.dispose();
  });

  test('enrollBiometric changePassword sonrası hâlâ geçerli (masterKey aynı)',
      () async {
    final s = await km.setup('Eski-Parola12');
    final token = sealToken(s.masterKey, 'SEED-DATA');
    final enroll = km.enrollBiometric(s.attrs, s.masterKey);

    // Parola değişir; copyWith bmk'yı korur
    final afterChange =
        await km.changePassword(enroll.attrs, s.masterKey, 'Yeni-Parola123');
    expect(afterChange.biometricEncryptedMasterKey, isNotNull);

    // Aynı biometricKey ile hâlâ açılır (masterKey değişmedi)
    final unlocked = km.biometricUnlock(afterChange, enroll.biometricKeyBytes);
    expect(canOpen(unlocked, token, 'SEED-DATA'), isTrue);

    enroll.biometricKeyBytes.fillRange(0, enroll.biometricKeyBytes.length, 0);
    s.masterKey.dispose();
    unlocked.dispose();
  });
}
