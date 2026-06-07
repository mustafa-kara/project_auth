/// SodiumCryptoService integration testleri (cihaz/simülatör — libsodium yüklenir).
///
/// `flutter test integration_test/sodium_crypto_service_test.dart -d <device>`
/// (Saf-Dart kripto olmayan testler `test/`te; bunlar gerçek libsodium ister.)
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:project_auth/core/crypto/crypto_exceptions.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/core/crypto/sodium_crypto_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late SodiumCryptoService crypto;

  setUpAll(() async {
    crypto = SodiumCryptoService();
    await crypto.init();
  });

  Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

  test('encrypt → decrypt round-trip (AAD ile)', () {
    final key = crypto.generateMasterKey();
    final pt = bytes('gizli totp secret');
    final aad = bytes('token|1|abc');

    final blob = crypto.encrypt(plaintext: pt, key: key, aad: aad);
    final out = crypto.decrypt(blob: blob, key: key, aad: aad);
    expect(out, pt);
    key.dispose();
  });

  test('yanlış key → DecryptException', () {
    final key1 = crypto.generateMasterKey();
    final key2 = crypto.generateMasterKey();
    final aad = bytes('token|1|abc');
    final blob = crypto.encrypt(plaintext: bytes('x'), key: key1, aad: aad);

    expect(
      () => crypto.decrypt(blob: blob, key: key2, aad: aad),
      throwsA(isA<DecryptException>()),
    );
    key1.dispose();
    key2.dispose();
  });

  test('yanlış AAD → DecryptException', () {
    final key = crypto.generateMasterKey();
    final blob = crypto.encrypt(plaintext: bytes('x'), key: key, aad: bytes('token|1|a'));
    expect(
      () => crypto.decrypt(blob: blob, key: key, aad: bytes('token|1|b')),
      throwsA(isA<DecryptException>()),
    );
    key.dispose();
  });

  test('ciphertext tamper (1 bit) → DecryptException', () {
    final key = crypto.generateMasterKey();
    final aad = bytes('token|1|abc');
    final blob = crypto.encrypt(plaintext: bytes('hello'), key: key, aad: aad);

    final ct = Uint8List.fromList(blob.ciphertext);
    ct[0] ^= 0x01;
    final tampered = EncryptedBlob(nonce: blob.nonce, ciphertext: ct);
    expect(
      () => crypto.decrypt(blob: tampered, key: key, aad: aad),
      throwsA(isA<DecryptException>()),
    );
    key.dispose();
  });

  test('nonce tamper → DecryptException', () {
    final key = crypto.generateMasterKey();
    final aad = bytes('token|1|abc');
    final blob = crypto.encrypt(plaintext: bytes('hello'), key: key, aad: aad);

    final n = Uint8List.fromList(blob.nonce);
    n[0] ^= 0x01;
    final tampered = EncryptedBlob(nonce: n, ciphertext: blob.ciphertext);
    expect(
      () => crypto.decrypt(blob: tampered, key: key, aad: aad),
      throwsA(isA<DecryptException>()),
    );
    key.dispose();
  });

  test('Argon2id determinizmi (fonksiyonel): aynı parola+salt+param → aynı KEK', () async {
    final params = crypto.defaultKdfParams();
    final salt = crypto.randomBytes(params.saltBytes);
    final aad = bytes('test|1');

    final kek1 = await crypto.deriveKek(
      password: 'parola123',
      salt: salt,
      opsLimit: params.opsLimit,
      memLimit: params.memLimit,
    );
    final blob = crypto.encrypt(plaintext: bytes('veri'), key: kek1, aad: aad);

    final kek2 = await crypto.deriveKek(
      password: 'parola123',
      salt: salt,
      opsLimit: params.opsLimit,
      memLimit: params.memLimit,
    );
    // Aynı parametrelerden türeyen KEK2, KEK1'in şifrelediğini çözebilmeli.
    final out = crypto.decrypt(blob: blob, key: kek2, aad: aad);
    expect(out, bytes('veri'));
    kek1.dispose();
    kek2.dispose();
  });

  test('farklı parola → farklı KEK (decrypt fail)', () async {
    final params = crypto.defaultKdfParams();
    final salt = crypto.randomBytes(params.saltBytes);
    final aad = bytes('test|1');

    final kek1 = await crypto.deriveKek(
      password: 'dogru', salt: salt, opsLimit: params.opsLimit, memLimit: params.memLimit);
    final blob = crypto.encrypt(plaintext: bytes('veri'), key: kek1, aad: aad);
    final kek2 = await crypto.deriveKek(
      password: 'yanlis', salt: salt, opsLimit: params.opsLimit, memLimit: params.memLimit);
    expect(
      () => crypto.decrypt(blob: blob, key: kek2, aad: aad),
      throwsA(isA<DecryptException>()),
    );
    kek1.dispose();
    kek2.dispose();
  });

  test('wrapKey → unwrapKey round-trip; yanlış wrappingKey fail', () {
    final master = crypto.generateMasterKey();
    final kek = crypto.generateMasterKey();
    final aad = bytes('masterkey-kek|1');

    // master'ı bir token şifrelemesinde kullan (kimliğini doğrulamak için)
    final tokenAad = bytes('token|1|t');
    final tokenBlob = crypto.encrypt(plaintext: bytes('SEED'), key: master, aad: tokenAad);

    final wrapped = crypto.wrapKey(keyToWrap: master, wrappingKey: kek, aad: aad);
    final unwrapped = crypto.unwrapKey(blob: wrapped, wrappingKey: kek, aad: aad);

    // unwrapped, master ile aynı → master'ın şifrelediği token'ı çözebilmeli.
    final out = crypto.decrypt(blob: tokenBlob, key: unwrapped, aad: tokenAad);
    expect(out, bytes('SEED'));

    // yanlış wrapping key → fail
    final wrongKek = crypto.generateMasterKey();
    expect(
      () => crypto.unwrapKey(blob: wrapped, wrappingKey: wrongKek, aad: aad),
      throwsA(isA<DecryptException>()),
    );

    master.dispose();
    kek.dispose();
    unwrapped.dispose();
    wrongKek.dispose();
  });
}
