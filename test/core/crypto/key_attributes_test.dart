/// KeyAttributes saf-Dart testleri (libsodium gerektirmez → plain `flutter test`).
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/core/crypto/key_attributes.dart';

Uint8List _salt([int fill = 3]) =>
    Uint8List.fromList(List.filled(KeyAttributes.saltBytes, fill));
Uint8List _nonce([int fill = 7]) =>
    Uint8List.fromList(List.filled(EncryptedBlob.nonceBytes, fill));
Uint8List _ct([int fill = 9]) =>
    Uint8List.fromList(List.filled(EncryptedBlob.minCiphertextBytes, fill));

EncryptedBlob _blob(int seed) =>
    EncryptedBlob(nonce: _nonce(seed), ciphertext: _ct(seed));

KeyAttributes _sample() => KeyAttributes(
      kdfSalt: _salt(),
      kdfOps: 3,
      kdfMem: 67108864,
      encryptedMasterKey: _blob(10),
      recoveryEncryptedMasterKey: _blob(20),
    );

void main() {
  test('JSON round-trip (tüm alanlar)', () {
    final a = _sample();
    final back = KeyAttributes.fromJson(a.toJson());
    expect(back.kdfSalt, a.kdfSalt);
    expect(back.kdfOps, 3);
    expect(back.kdfMem, 67108864);
    expect(back.encryptedMasterKey.nonce, a.encryptedMasterKey.nonce);
    expect(back.encryptedMasterKey.ciphertext, a.encryptedMasterKey.ciphertext);
    expect(back.recoveryEncryptedMasterKey.ciphertext,
        a.recoveryEncryptedMasterKey.ciphertext);
    expect(back.version, 1);
  });

  test('defensive copy: ctor girişini ve getter çıkışını izole eder', () {
    final salt = _salt(1);
    final a = KeyAttributes(
      kdfSalt: salt,
      kdfOps: 1,
      kdfMem: 1,
      encryptedMasterKey: _blob(1),
      recoveryEncryptedMasterKey: _blob(2),
    );
    salt[0] = 99; // dış mutasyon
    expect(a.kdfSalt[0], 1);
    final got = a.kdfSalt;
    got[0] = 77; // getter çıktısı mutasyonu
    expect(a.kdfSalt[0], 1);
  });

  test('copyWith: kdf + encryptedMasterKey güncellenir, recovery korunur', () {
    final a = _sample();
    final newSalt = _salt(8);
    final newEmk = _blob(55);
    final b = a.copyWith(
        kdfSalt: newSalt, kdfOps: 4, kdfMem: 999, encryptedMasterKey: newEmk);
    expect(b.kdfSalt, newSalt);
    expect(b.kdfOps, 4);
    expect(b.kdfMem, 999);
    expect(b.encryptedMasterKey.ciphertext, newEmk.ciphertext);
    // recovery DOKUNULMAZ
    expect(b.recoveryEncryptedMasterKey.ciphertext,
        a.recoveryEncryptedMasterKey.ciphertext);
  });

  test('eksik alan → FormatException', () {
    final full = _sample().toJson();
    for (final key in ['salt', 'ops', 'mem', 'emk', 'remk']) {
      final partial = Map<String, dynamic>.from(full)..remove(key);
      expect(() => KeyAttributes.fromJson(partial), throwsFormatException,
          reason: 'eksik: $key');
    }
  });

  test('yanlış tip → FormatException', () {
    final j = _sample().toJson()..['ops'] = 'üç';
    expect(() => KeyAttributes.fromJson(j), throwsFormatException);
    final j2 = _sample().toJson()..['emk'] = 'notamap';
    expect(() => KeyAttributes.fromJson(j2), throwsFormatException);
  });

  test('geçersiz base64 salt → FormatException', () {
    final j = _sample().toJson()..['salt'] = '!!!';
    expect(() => KeyAttributes.fromJson(j), throwsFormatException);
  });

  // --- Sıkı validasyon (review P2) ---

  test('yanlış salt uzunluğu → FormatException', () {
    expect(
        () => KeyAttributes(
              kdfSalt: Uint8List(KeyAttributes.saltBytes - 1),
              kdfOps: 1,
              kdfMem: 1,
              encryptedMasterKey: _blob(1),
              recoveryEncryptedMasterKey: _blob(2),
            ),
        throwsFormatException);
  });

  test('negatif / sıfır KDF değerleri → FormatException', () {
    KeyAttributes make(int ops, int mem) => KeyAttributes(
          kdfSalt: _salt(),
          kdfOps: ops,
          kdfMem: mem,
          encryptedMasterKey: _blob(1),
          recoveryEncryptedMasterKey: _blob(2),
        );
    expect(() => make(0, 1), throwsFormatException);
    expect(() => make(-1, 1), throwsFormatException);
    expect(() => make(1, 0), throwsFormatException);
    expect(() => make(1, -5), throwsFormatException);
  });

  test('ileri version → FormatException', () {
    final j = _sample().toJson()..['v'] = 99;
    expect(() => KeyAttributes.fromJson(j), throwsFormatException);
  });

  test('kesirli ops → FormatException (sessiz truncate yok)', () {
    final j = _sample().toJson()..['ops'] = 1.5;
    expect(() => KeyAttributes.fromJson(j), throwsFormatException);
  });

  test('tamsayı değerli double (3.0) kabul edilir', () {
    final j = _sample().toJson()..['ops'] = 3.0;
    expect(KeyAttributes.fromJson(j).kdfOps, 3);
  });
}
