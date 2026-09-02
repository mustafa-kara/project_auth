/// [CryptoService]'in libsodium (sodium_libs/sumo) implementasyonu.
///
/// sodium 3.4.6 + sodium_libs 3.4.6+4 (Dart 3.10.7 toolchain — sodium 4.x
/// Dart 3.11+ ister). Init: SodiumSumoInit.init() (pwhash sumo-only).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium_libs/sodium_libs_sumo.dart';

import 'crypto_exceptions.dart';
import 'crypto_service.dart';
import 'encrypted_blob.dart';
import 'key_handle.dart';

/// [SecureKey]'i saran opaque tutamaç. `SecureKey` dışarı sızmaz.
class SodiumKeyHandle implements KeyHandle {
  final SecureKey secureKey;
  bool _disposed = false;

  SodiumKeyHandle(this.secureKey);

  @override
  void dispose() {
    if (_disposed) return; // idempotent (çift-dispose guard)
    _disposed = true;
    secureKey.dispose();
  }
}

class SodiumCryptoService implements CryptoService {
  late final SodiumSumo _sodium;
  bool _initialized = false;

  Aead get _aead => _sodium.crypto.aeadXChaCha20Poly1305IETF;

  @override
  Future<void> init() async {
    if (_initialized) return;
    _sodium = await SodiumSumoInit.init();
    _initialized = true;
  }

  @override
  KeyHandle generateMasterKey() =>
      SodiumKeyHandle(_sodium.secureRandom(_aead.keyBytes));

  @override
  KdfParams defaultKdfParams() {
    final pw = _sodium.crypto.pwhash;
    return (
      opsLimit: pw.opsLimitModerate,
      memLimit: pw.memLimitModerate,
      saltBytes: pw.saltBytes,
    );
  }

  @override
  Future<KeyHandle> deriveKek({
    required String password,
    required Uint8List salt,
    required int opsLimit,
    required int memLimit,
  }) async {
    final outLen = _aead.keyBytes;
    // Argon2id ağır → ayrı isolate (UI bloklamaz; sodium dokümanı "mandatory").
    // SodiumSumoIsolateCallback 3-arg: (sodium, secureKeys, keyPairs) — sodium
    // isolate-LOCAL instance olarak gelir (capture edilen değil → isolate-safe).
    // Parola birebir UTF-8 (normalization yok — bkz. docs/CRYPTO.md).
    final kek = await _sodium.runIsolated((sodium, secureKeys, keyPairs) {
      final passwordI8 = Int8List.fromList(utf8.encode(password));
      try {
        return sodium.crypto.pwhash(
          outLen: outLen,
          password: passwordI8,
          salt: salt,
          opsLimit: opsLimit,
          memLimit: memLimit,
          alg: CryptoPwhashAlgorithm.argon2id13,
        );
      } finally {
        passwordI8.fillRange(
          0,
          passwordI8.length,
          0,
        ); // izole içi byte zero-fill
      }
    });
    return SodiumKeyHandle(kek);
  }

  @override
  KeyHandle keyFromBytes(Uint8List bytes) =>
      SodiumKeyHandle(_sodium.secureCopy(bytes));

  @override
  EncryptedBlob encrypt({
    required Uint8List plaintext,
    required KeyHandle key,
    required Uint8List aad,
  }) {
    final nonce = _sodium.randombytes.buf(_aead.nonceBytes);
    final ct = _aead.encrypt(
      message: plaintext,
      nonce: nonce,
      key: _secureKey(key),
      additionalData: aad,
    );
    return EncryptedBlob(nonce: nonce, ciphertext: ct);
  }

  @override
  Uint8List decrypt({
    required EncryptedBlob blob,
    required KeyHandle key,
    required Uint8List aad,
  }) {
    try {
      return _aead.decrypt(
        cipherText: blob.ciphertext,
        nonce: blob.nonce,
        key: _secureKey(key),
        additionalData: aad,
      );
    } catch (_) {
      throw const DecryptException();
    }
  }

  @override
  EncryptedBlob wrapKey({
    required KeyHandle keyToWrap,
    required KeyHandle wrappingKey,
    required Uint8List aad,
  }) {
    // SecureKey'i geçici olarak ham byte'a çıkar → şifrele → byte'ı hemen sil.
    final raw = _secureKey(keyToWrap).extractBytes();
    try {
      final nonce = _sodium.randombytes.buf(_aead.nonceBytes);
      final ct = _aead.encrypt(
        message: raw,
        nonce: nonce,
        key: _secureKey(wrappingKey),
        additionalData: aad,
      );
      return EncryptedBlob(nonce: nonce, ciphertext: ct);
    } finally {
      raw.fillRange(0, raw.length, 0); // ham anahtar byte'ını zero-fill
    }
  }

  @override
  KeyHandle unwrapKey({
    required EncryptedBlob blob,
    required KeyHandle wrappingKey,
    required Uint8List aad,
  }) {
    final Uint8List plain;
    try {
      plain = _aead.decrypt(
        cipherText: blob.ciphertext,
        nonce: blob.nonce,
        key: _secureKey(wrappingKey),
        additionalData: aad,
      );
    } catch (_) {
      throw const DecryptException();
    }
    try {
      return SodiumKeyHandle(_sodium.secureCopy(plain)); // çift-wrap yok
    } finally {
      plain.fillRange(0, plain.length, 0); // çözülen ham anahtarı zero-fill
    }
  }

  @override
  Uint8List randomBytes(int n) => _sodium.randombytes.buf(n);

  SecureKey _secureKey(KeyHandle h) => (h as SodiumKeyHandle).secureKey;
}
