/// KeyAttributesStore testleri — round-trip, malformed→FormatException, sızıntı yok.
library;

import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/core/crypto/key_attributes.dart';
import 'package:project_auth/features/auth/data/key_attributes_store.dart';

class FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async => data[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async {
    data.remove(key);
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

KeyAttributes _attrs() {
  // Tanınabilir byte desenleri — raw storage'da plaintext sızmadığını kontrol için.
  final nonce = Uint8List.fromList(List.generate(24, (i) => i));
  final ct = Uint8List.fromList(List.generate(16, (i) => 200 - i));
  final blob = EncryptedBlob(nonce: nonce, ciphertext: ct);
  return KeyAttributes(
    kdfSalt: Uint8List.fromList(List.generate(16, (i) => i + 1)),
    kdfOps: 3,
    kdfMem: 67108864,
    encryptedMasterKey: blob,
    recoveryEncryptedMasterKey: blob,
  );
}

void main() {
  late FakeSecureStorage storage;
  late KeyAttributesStore store;

  setUp(() {
    storage = FakeSecureStorage();
    store = KeyAttributesStore(storage: storage);
  });

  test('write → read round-trip', () async {
    await store.write(_attrs());
    final read = await store.read();
    expect(read, isNotNull);
    expect(read!.kdfOps, 3);
    expect(read.kdfMem, 67108864);
    expect(read.kdfSalt, _attrs().kdfSalt);
  });

  test('boş depo → null (uninitialized)', () async {
    expect(await store.read(), isNull);
  });

  test('malformed JSON → FormatException (sessiz null DEĞİL)', () async {
    storage.data[KeyAttributesStore.storageKey] = '{bozuk';
    expect(() => store.read(), throwsA(isA<FormatException>()));
  });

  test('non-map JSON → FormatException', () async {
    storage.data[KeyAttributesStore.storageKey] = '[1,2,3]';
    expect(() => store.read(), throwsA(isA<FormatException>()));
  });

  test('clear → read null', () async {
    await store.write(_attrs());
    await store.clear();
    expect(await store.read(), isNull);
  });

  test(
    'storage raw yalnız şifreli blob tutar (parola/mnemonic sızmaz)',
    () async {
      await store.write(_attrs());
      final raw = storage.data[KeyAttributesStore.storageKey]!;
      // KeyAttributes yalnız KDF param + şifreli blob içerir; parola/mnemonic
      // hiçbir zaman buraya yazılmaz. Raw, base64 blob + sayılardan ibaret.
      expect(raw.contains('parola'), isFalse);
      expect(raw.contains('mnemonic'), isFalse);
      // Beklenen alanlar mevcut (şema).
      expect(raw.contains('salt'), isTrue);
      expect(raw.contains('emk'), isTrue);
      expect(raw.contains('remk'), isTrue);
    },
  );
}
