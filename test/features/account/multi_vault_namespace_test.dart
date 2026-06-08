/// Multi-vault namespace + legacy bağlama testleri (Faz 3 Patch 1, kullanıcı kararı 7).
///
/// libsodium GEREKMEZ — KeyAttributesStore/AccountVaultManager storage-katmanı +
/// fake biyometri. Namespace izolasyonu + legacy migration (`bmk` temizleme) +
/// per-uid karar marker + `linkRequired` döngü-önleme doğrulanır.
library;

import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/core/crypto/key_attributes.dart';
import 'package:project_auth/features/account/data/active_account_store.dart';
import 'package:project_auth/features/account/data/legacy_link_store.dart';
import 'package:project_auth/features/account/domain/account_vault_manager.dart';
import 'package:project_auth/features/auth/data/key_attributes_store.dart';
import 'package:project_auth/features/auth/domain/biometric_service.dart';
import 'package:project_auth/features/vault/data/encrypted_vault_repository.dart';

class _FakeStorage implements FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async => data[key];
  @override
  Future<void> write({required String key, required String? value, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async => data.remove(key);
  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

class _FakeBiometric implements BiometricService {
  int disableCount = 0;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<void> enroll(Uint8List keyBytes) async {}
  @override
  Future<Uint8List> retrieve() async => Uint8List(32);
  @override
  Future<void> disable() async => disableCount++;
}

KeyAttributes _attrs({bool withBmk = false}) {
  final blob = EncryptedBlob(nonce: Uint8List(24), ciphertext: Uint8List(16));
  return KeyAttributes(
    kdfSalt: Uint8List(KeyAttributes.saltBytes),
    kdfOps: 2,
    kdfMem: 67108864,
    encryptedMasterKey: blob,
    recoveryEncryptedMasterKey: blob,
    biometricEncryptedMasterKey: withBmk ? blob : null,
  );
}

void main() {
  late _FakeStorage storage;
  late _FakeBiometric biometric;
  late AccountVaultManager manager;

  setUp(() {
    storage = _FakeStorage();
    biometric = _FakeBiometric();
    manager = AccountVaultManager(
      storage: storage,
      activeStore: ActiveAccountStore(storage: storage),
      legacyStore: LegacyLinkStore(storage: storage),
      biometric: biometric,
    );
  });

  test('namespace izolasyonu: uid A attrs → uid B namespace null', () async {
    final prefixA = AccountVaultManager.prefixFor('uid-A');
    final prefixB = AccountVaultManager.prefixFor('uid-B');
    await KeyAttributesStore(storage: storage, keyPrefix: prefixA)
        .write(_attrs());
    expect(await KeyAttributesStore(storage: storage, keyPrefix: prefixA).read(),
        isNotNull);
    expect(await KeyAttributesStore(storage: storage, keyPrefix: prefixB).read(),
        isNull, reason: 'B, A\'nın attrs\'ını görmemeli');
  });

  test('legacyVaultExists: uid-siz attrs varsa true', () async {
    expect(await manager.legacyVaultExists(), isFalse);
    await KeyAttributesStore(storage: storage).write(_attrs()); // uid-siz
    expect(await manager.legacyVaultExists(), isTrue);
  });

  test('linkRequired: legacy var + karar yok → true; karar verilince → false', () async {
    await KeyAttributesStore(storage: storage).write(_attrs());
    expect(await manager.linkRequired('uid-A'), isTrue);
    await manager.startFreshVault('uid-A'); // karar (yeni vault)
    expect(await manager.linkRequired('uid-A'), isFalse);
  });

  test('linkLegacyToUser: anahtarlar uid namespace\'ine taşınır + bmk TEMİZLENİR + '
      'disable çağrılır + legacy tüketilir (reviewer [P1])', () async {
    // Legacy (uid-siz) vault: bmk\'lı attrs + encrypted vault + view + marker.
    await KeyAttributesStore(storage: storage).write(_attrs(withBmk: true));
    storage.data[EncryptedVaultRepository.vaultKey] = '[{"id":"x"}]';
    storage.data['vault_view_mode_v1'] = 'list';

    await manager.linkLegacyToUser('uid-A');
    final prefix = AccountVaultManager.prefixFor('uid-A');

    // attrs taşındı + bmk temizlendi.
    final moved =
        await KeyAttributesStore(storage: storage, keyPrefix: prefix).read();
    expect(moved, isNotNull);
    expect(moved!.biometricEncryptedMasterKey, isNull,
        reason: 'bmk taşınmaz, temizlenir');

    // encrypted vault taşındı (ciphertext aynen).
    expect(storage.data['$prefix${EncryptedVaultRepository.vaultKey}'],
        '[{"id":"x"}]');

    // biometric.disable çağrıldı.
    expect(biometric.disableCount, 1);

    // legacy TÜKETİLDİ (uid-siz anahtarlar silindi) → artık linkRequired false.
    expect(await manager.legacyVaultExists(), isFalse);
    expect(await manager.linkRequired('uid-A'), isFalse);

    // aktif uid yazıldı.
    expect(await manager.activeUid(), 'uid-A');
  });

  test('startFreshVault: legacy\'ye DOKUNMAZ ama bu uid kararlı → linkRequired false; '
      'PER-UID: başka uid\'e legacy YİNE teklif edilir (reviewer [P3])', () async {
    await KeyAttributesStore(storage: storage).write(_attrs());

    await manager.startFreshVault('uid-A');
    expect(await manager.linkRequired('uid-A'), isFalse); // A karar verdi
    expect(await manager.legacyVaultExists(), isTrue); // legacy DURUYOR

    // B henüz karar vermedi → legacy YİNE teklif edilir.
    expect(await manager.linkRequired('uid-B'), isTrue);
    expect(await manager.activeUid(), 'uid-A');
  });
}
