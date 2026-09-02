/// EncryptedBlob saf-Dart testleri (libsodium gerektirmez → plain `flutter test`).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';

/// Geçerli (kanonik uzunlukta) nonce/ciphertext üreticileri.
Uint8List _nonce([int fill = 7]) =>
    Uint8List.fromList(List.filled(EncryptedBlob.nonceBytes, fill));
Uint8List _ct([int fill = 9, int len = EncryptedBlob.minCiphertextBytes]) =>
    Uint8List.fromList(List.filled(len, fill));

void main() {
  test('JSON round-trip (base64)', () {
    final blob = EncryptedBlob(nonce: _nonce(1), ciphertext: _ct(2, 20));
    final back = EncryptedBlob.fromJson(blob.toJson());
    expect(back.nonce, blob.nonce);
    expect(back.ciphertext, blob.ciphertext);
    expect(back.version, 1);
  });

  test('version yoksa varsayılan 1', () {
    final j = EncryptedBlob(nonce: _nonce(), ciphertext: _ct()).toJson()
      ..remove('v');
    expect(EncryptedBlob.fromJson(j).version, 1);
  });

  test('defensive copy: ctor girişini ve getter çıkışını izole eder', () {
    final src = _nonce(1);
    final blob = EncryptedBlob(nonce: src, ciphertext: _ct());
    src[0] = 99; // dış mutasyon
    expect(blob.nonce[0], 1); // etkilenmemeli

    final got = blob.nonce;
    got[0] = 77; // getter çıktısını mutate et
    expect(blob.nonce[0], 1); // iç buffer korunmalı
  });

  test('eksik alan → FormatException', () {
    expect(
      () => EncryptedBlob.fromJson({'n': base64Encode(_nonce())}),
      throwsFormatException,
    );
    expect(
      () => EncryptedBlob.fromJson({'c': base64Encode(_ct())}),
      throwsFormatException,
    );
  });

  test('yanlış tip → FormatException', () {
    expect(
      () => EncryptedBlob.fromJson({'n': 123, 'c': base64Encode(_ct())}),
      throwsFormatException,
    );
    final valid = EncryptedBlob(nonce: _nonce(), ciphertext: _ct()).toJson();
    expect(
      () => EncryptedBlob.fromJson({...valid, 'v': 'x'}),
      throwsFormatException,
    );
  });

  test('geçersiz base64 → FormatException', () {
    expect(
      () => EncryptedBlob.fromJson({'n': '!!!', 'c': base64Encode(_ct())}),
      throwsFormatException,
    );
  });

  // --- Sıkı validasyon (review P2) ---

  test('yanlış nonce uzunluğu → FormatException (ctor + fromJson)', () {
    expect(
      () => EncryptedBlob(
        nonce: Uint8List(EncryptedBlob.nonceBytes - 1),
        ciphertext: _ct(),
      ),
      throwsFormatException,
    );
    // fromJson da ctor'a düştüğü için aynı korunur
    final j = {'n': base64Encode(Uint8List(4)), 'c': base64Encode(_ct())};
    expect(() => EncryptedBlob.fromJson(j), throwsFormatException);
  });

  test('çok kısa ciphertext (< tag) → FormatException', () {
    expect(
      () => EncryptedBlob(
        nonce: _nonce(),
        ciphertext: Uint8List(EncryptedBlob.minCiphertextBytes - 1),
      ),
      throwsFormatException,
    );
  });

  test('desteklenmeyen ileri version → FormatException', () {
    expect(
      () => EncryptedBlob(nonce: _nonce(), ciphertext: _ct(), version: 99),
      throwsFormatException,
    );
    expect(
      () => EncryptedBlob(nonce: _nonce(), ciphertext: _ct(), version: 0),
      throwsFormatException,
    );
    final j = EncryptedBlob(nonce: _nonce(), ciphertext: _ct()).toJson()
      ..['v'] = 99;
    expect(() => EncryptedBlob.fromJson(j), throwsFormatException);
  });

  test('kesirli version → FormatException (sessiz truncate yok)', () {
    final j = EncryptedBlob(nonce: _nonce(), ciphertext: _ct()).toJson()
      ..['v'] = 1.5;
    expect(() => EncryptedBlob.fromJson(j), throwsFormatException);
  });
}
