/// Shared host-VM stand-in for [CryptoService].
///
/// libsodium's platform plugin does not load on the plain `flutter test` VM
/// (docs/CRYPTO.md §10), so every host test that needs encrypt/decrypt uses this
/// round-trip fake. Real primitives are exercised in `integration_test/`.
///
/// It is deliberately NOT secure — it is an oracle with three properties the
/// tests depend on:
///  * round-trip: `decrypt(encrypt(p)) == p`
///  * AAD binding: a different AAD on read fails, like a real AEAD tag check
///  * key binding: a key derived from a different password fails
///
/// Key binding is opt-in: a [KeyHandle] with no material (the default
/// [FakeKeyHandle], or any other stub implementing [KeyHandle]) behaves as a
/// wildcard, so tests that only care about storage behaviour can keep passing
/// throw-away handles.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:project_auth/core/crypto/crypto_exceptions.dart';
import 'package:project_auth/core/crypto/crypto_service.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/core/crypto/key_handle.dart';

/// Opaque handle carrying optional key material. [material] is what makes two
/// handles compare unequal inside [FakeCrypto]; an empty one is the wildcard.
class FakeKeyHandle implements KeyHandle {
  final Uint8List material;
  bool disposed = false;

  FakeKeyHandle([Uint8List? material])
      : material = Uint8List.fromList(material ?? Uint8List(0));

  @override
  void dispose() => disposed = true;
}

/// Round-trip fake: ciphertext = 16-byte tag + key id + AAD + plaintext.
class FakeCrypto implements CryptoService {
  /// Increments on every [randomBytes] call so successive salts/nonces differ
  /// while staying fully deterministic across runs.
  int _counter = 0;

  @override
  Future<void> init() async {}

  @override
  KeyHandle generateMasterKey() => FakeKeyHandle(randomBytes(32));

  /// Deliberately cheap Argon2id parameters. `saltBytes` matches the real
  /// `crypto_pwhash_SALTBYTES` (16) so salt-length handling is faithful; the
  /// cost values are far below production and below `BackupEnvelope`'s accepted
  /// floor — backup tests use [BackupFakeCrypto] instead.
  @override
  KdfParams defaultKdfParams() =>
      (opsLimit: 2, memLimit: 1 << 20, saltBytes: 16);

  /// Deterministic stand-in for Argon2id: `sha256(utf8(password) + salt)`.
  /// Same password + salt → same key; anything else → a different key, which is
  /// all a wrong-password test needs.
  @override
  Future<KeyHandle> deriveKek({
    required String password,
    required Uint8List salt,
    required int opsLimit,
    required int memLimit,
  }) async {
    final digest = sha256.convert(<int>[...utf8.encode(password), ...salt]);
    return FakeKeyHandle(Uint8List.fromList(digest.bytes));
  }

  @override
  KeyHandle keyFromBytes(Uint8List bytes) => FakeKeyHandle(bytes);

  @override
  EncryptedBlob encrypt({
    required Uint8List plaintext,
    required KeyHandle key,
    required Uint8List aad,
  }) {
    // ciphertext: [16B tag][keyLen:2][keyId][aadLen:2][aad][plaintext].
    // Lengths are 2 bytes (big-endian) so a long AAD cannot silently overflow.
    final keyId = _keyId(key);
    final body = <int>[
      ..._tag(keyId, aad, plaintext),
      ..._len(keyId.length),
      ...keyId,
      ..._len(aad.length),
      ...aad,
      ...plaintext,
    ];
    return EncryptedBlob(
      nonce: Uint8List(24),
      ciphertext: Uint8List.fromList(body),
    );
  }

  @override
  Uint8List decrypt({
    required EncryptedBlob blob,
    required KeyHandle key,
    required Uint8List aad,
  }) {
    final c = blob.ciphertext;
    var offset = 16;
    final keyLen = (c[offset] << 8) | c[offset + 1];
    offset += 2;
    final storedKey = c.sublist(offset, offset + keyLen);
    offset += keyLen;
    final aadLen = (c[offset] << 8) | c[offset + 1];
    offset += 2;
    final storedAad = c.sublist(offset, offset + aadLen);
    offset += aadLen;
    if (!_eq(storedKey, _keyId(key))) {
      throw const DecryptException('FakeCrypto: key mismatch');
    }
    if (!_eq(storedAad, aad)) {
      // Real sodium reports a failed tag check as DecryptException regardless of
      // whether the key or the AAD is wrong; the fake matches that so callers
      // can be tested against the production error type.
      throw const DecryptException('FakeCrypto: AAD mismatch (tamper)');
    }
    final plaintext = Uint8List.fromList(c.sublist(offset));
    if (!_eq(c.sublist(0, 16), _tag(storedKey, storedAad, plaintext))) {
      throw const DecryptException('FakeCrypto: tag mismatch (tamper)');
    }
    return plaintext;
  }

  /// Stand-in for the Poly1305 tag: any edit to the key id, the AAD or the
  /// ciphertext body is detected, so tamper tests behave as they do with sodium.
  static List<int> _tag(List<int> keyId, List<int> aad, List<int> plaintext) =>
      sha256.convert(<int>[...keyId, 0, ...aad, 0, ...plaintext]).bytes
          .sublist(0, 16);

  @override
  EncryptedBlob wrapKey({
    required KeyHandle keyToWrap,
    required KeyHandle wrappingKey,
    required Uint8List aad,
  }) =>
      encrypt(plaintext: _keyId(keyToWrap), key: wrappingKey, aad: aad);

  @override
  KeyHandle unwrapKey({
    required EncryptedBlob blob,
    required KeyHandle wrappingKey,
    required Uint8List aad,
  }) =>
      FakeKeyHandle(decrypt(blob: blob, key: wrappingKey, aad: aad));

  /// Deterministic "random": byte i = (counter + i) mod 256.
  @override
  Uint8List randomBytes(int n) {
    final seed = ++_counter;
    return Uint8List.fromList(
        List<int>.generate(n, (i) => (seed + i) & 0xff, growable: false));
  }

  /// A handle with no material is a wildcard (empty id) → matches any other
  /// wildcard, which preserves the behaviour of the pre-existing inline fake.
  static Uint8List _keyId(KeyHandle key) =>
      key is FakeKeyHandle ? key.material : Uint8List(0);

  static List<int> _len(int n) {
    if (n > 0xffff) throw ArgumentError.value(n, 'length', 'too long for the fake');
    return <int>[(n >> 8) & 0xff, n & 0xff];
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// [FakeCrypto] with envelope-legal Argon2id parameters.
///
/// The base fake's 1 MiB cost is deliberately below `BackupEnvelope`'s 8 MiB
/// floor — it is sized for vault tests that never build an envelope. Backup
/// tests need parameters the envelope accepts, with headroom on both values so a
/// downgrade test can actually move them.
class BackupFakeCrypto extends FakeCrypto {
  @override
  KdfParams defaultKdfParams() =>
      (opsLimit: 3, memLimit: 64 * 1024 * 1024, saltBytes: 16);
}
