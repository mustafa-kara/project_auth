/// `KeyManager.enrollBiometric`'in HATA yolundaki bellek hijyeni
/// (güvenlik denetimi P3-6).
///
/// Başarı yolunda `biometricKeyBytes`'ın sahipliği ÇAĞIRANA taşınır ve onu
/// `VaultLockCubit.enableBiometric` bir `finally` içinde sıfırlar. Hata yolunda
/// ise byte'lar kimseye taşınmaz: `keyFromBytes`/`wrapKey` fırlatırsa istisna
/// yukarı çıkar, tampon hiçbir yere gitmez ve onu silecek kimse kalmaz — yani
/// ham 32 baytlık biometricKey yığında temizlenmemiş olarak asılı kalırdı.
///
/// libsodium GEREKMEZ — `CryptoService` fake'lenir (yalnız `enrollBiometric`
/// yolunda kullanılan üç üye gerçek davranış gösterir).
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/crypto_exceptions.dart';
import 'package:project_auth/core/crypto/crypto_service.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/core/crypto/key_attributes.dart';
import 'package:project_auth/core/crypto/key_handle.dart';
import 'package:project_auth/features/auth/domain/key_manager.dart';

class _FakeKeyHandle implements KeyHandle {
  bool disposed = false;
  @override
  void dispose() => disposed = true;
}

/// `enrollBiometric`'in dokunduğu üyeleri gerçekleyen sahte servis; geri kalanı
/// çağrılırsa test AÇIKÇA patlasın diye `noSuchMethod` fırlatır.
class _FakeCrypto implements CryptoService {
  /// `randomBytes`'ın döndürdüğü SON tampon — test bunun sıfırlandığını sorar.
  Uint8List? lastRandom;

  /// Hangi adım fırlatsın? (null → hiçbiri, başarı yolu.)
  Object? keyFromBytesError;
  Object? wrapError;

  final List<_FakeKeyHandle> issued = [];

  @override
  Uint8List randomBytes(int n) {
    // Sıfır OLMAYAN bir tampon: "silindi mi" testi anlamlı olsun.
    final b = Uint8List.fromList(List.generate(n, (i) => (i % 255) + 1));
    lastRandom = b;
    return b;
  }

  @override
  KeyHandle keyFromBytes(Uint8List bytes) {
    if (keyFromBytesError != null) throw keyFromBytesError!;
    final k = _FakeKeyHandle();
    issued.add(k);
    return k;
  }

  @override
  EncryptedBlob wrapKey({
    required KeyHandle keyToWrap,
    required KeyHandle wrappingKey,
    required Uint8List aad,
  }) {
    if (wrapError != null) throw wrapError!;
    return EncryptedBlob(nonce: Uint8List(24), ciphertext: Uint8List(16));
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('_FakeCrypto: ${i.memberName}');
}

KeyAttributes _attrs() {
  final blob = EncryptedBlob(nonce: Uint8List(24), ciphertext: Uint8List(16));
  return KeyAttributes(
    kdfSalt: Uint8List(KeyAttributes.saltBytes),
    kdfOps: 2,
    kdfMem: 67108864,
    encryptedMasterKey: blob,
    recoveryEncryptedMasterKey: blob,
  );
}

void main() {
  late _FakeCrypto crypto;
  late KeyManager km;

  setUp(() {
    crypto = _FakeCrypto();
    km = KeyManager(crypto);
  });

  test('BAŞARI: byte\'lar çağırana taşınır (burada silinmez)', () {
    final result = km.enrollBiometric(_attrs(), _FakeKeyHandle());
    expect(result.attrs.biometricEncryptedMasterKey, isNotNull);
    expect(
      result.biometricKeyBytes.any((b) => b != 0),
      isTrue,
      reason:
          'sahiplik çağırana geçer; silme sorumluluğu onda '
          '(VaultLockCubit.enableBiometric finally)',
    );
    expect(crypto.issued.single.disposed, isTrue); // ara handle dispose
  });

  test('keyFromBytes FIRLATIRSA ham byte\'lar SIFIRLANIR (P3-6)', () {
    crypto.keyFromBytesError = const DecryptException();
    expect(
      () => km.enrollBiometric(_attrs(), _FakeKeyHandle()),
      throwsA(isA<DecryptException>()),
    );
    final bytes = crypto.lastRandom!;
    expect(
      bytes.every((b) => b == 0),
      isTrue,
      reason: 'byte\'lar kimseye taşınmadı → burada silinmeliydi',
    );
  });

  test('wrapKey FIRLATIRSA ham byte\'lar SIFIRLANIR + handle dispose', () {
    crypto.wrapError = const DecryptException();
    expect(
      () => km.enrollBiometric(_attrs(), _FakeKeyHandle()),
      throwsA(isA<DecryptException>()),
    );
    expect(crypto.lastRandom!.every((b) => b == 0), isTrue);
    expect(crypto.issued.single.disposed, isTrue);
  });
}
