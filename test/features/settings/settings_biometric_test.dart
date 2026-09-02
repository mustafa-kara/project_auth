/// Biyometri UI testleri (Patch 5): UnlockPage buton görünürlüğü + Settings switch.
///
/// libsodium GEREKMEZ — KeyManager + BiometricService fake. VaultLockCubit state'i
/// doğrudan kurulup widget'ların doğru tepki verdiği doğrulanır.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/core/crypto/key_attributes.dart';
import 'package:project_auth/core/crypto/key_handle.dart';
import 'package:project_auth/features/auth/data/key_attributes_store.dart';
import 'package:project_auth/features/auth/domain/biometric_service.dart';
import 'package:project_auth/features/auth/domain/key_manager.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/pages/unlock_page.dart';
import 'package:project_auth/features/settings/presentation/settings_page.dart';

class _FakeKeyHandle implements KeyHandle {
  @override
  void dispose() {}
}

class _FakeStorage implements FlutterSecureStorage {
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
  }) async => data.remove(key);
  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
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

class _FakeKeyManager implements KeyManager {
  @override
  Future<KeyHandle> unlock(KeyAttributes attrs, String p) async =>
      _FakeKeyHandle();

  @override
  BiometricEnrollResult enrollBiometric(
    KeyAttributes attrs,
    KeyHandle masterKey,
  ) {
    final blob = EncryptedBlob(nonce: Uint8List(24), ciphertext: Uint8List(16));
    return (
      attrs: attrs.copyWith(biometricEncryptedMasterKey: blob),
      biometricKeyBytes: Uint8List(32),
    );
  }

  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

class _FakeBiometric implements BiometricService {
  final bool available;
  int enrollCount = 0;
  int disableCount = 0;
  _FakeBiometric({this.available = true});
  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<void> enroll(Uint8List keyBytes) async => enrollCount++;
  @override
  Future<Uint8List> retrieve() async => Uint8List(32);
  @override
  Future<void> disable() async => disableCount++;
}

VaultLockCubit _cubit(_FakeStorage storage, _FakeBiometric bio) =>
    VaultLockCubit(
      keyManager: _FakeKeyManager(),
      attrsStore: KeyAttributesStore(storage: storage),
      biometric: bio,
      migrate: (_) async {},
      deleteKeys: (_) async {},
    );

void main() {
  group('UnlockPage biyometri butonu', () {
    testWidgets('enrolled + available → buton görünür', (tester) async {
      final storage = _FakeStorage();
      await KeyAttributesStore(storage: storage).write(_attrs(withBmk: true));
      final cubit = _cubit(storage, _FakeBiometric(available: true));
      await cubit.bootstrap();

      await tester.pumpWidget(
        MaterialApp(
          home: BlocProvider.value(value: cubit, child: const UnlockPage()),
        ),
      );
      expect(find.text('Biyometri ile aç'), findsOneWidget);
      await cubit.close();
    });

    testWidgets('enrolled ama cihaz unavailable → buton GİZLİ', (tester) async {
      final storage = _FakeStorage();
      await KeyAttributesStore(storage: storage).write(_attrs(withBmk: true));
      final cubit = _cubit(storage, _FakeBiometric(available: false));
      await cubit.bootstrap();

      await tester.pumpWidget(
        MaterialApp(
          home: BlocProvider.value(value: cubit, child: const UnlockPage()),
        ),
      );
      expect(find.text('Biyometri ile aç'), findsNothing);
      await cubit.close();
    });

    testWidgets('enrolled değil → buton GİZLİ', (tester) async {
      final storage = _FakeStorage();
      await KeyAttributesStore(storage: storage).write(_attrs());
      final cubit = _cubit(storage, _FakeBiometric(available: true));
      await cubit.bootstrap();

      await tester.pumpWidget(
        MaterialApp(
          home: BlocProvider.value(value: cubit, child: const UnlockPage()),
        ),
      );
      expect(find.text('Biyometri ile aç'), findsNothing);
      await cubit.close();
    });
  });

  group('SettingsPage switch', () {
    Future<VaultLockCubit> unlockedCubit(
      _FakeStorage storage,
      _FakeBiometric bio,
    ) async {
      await KeyAttributesStore(storage: storage).write(_attrs());
      final cubit = _cubit(storage, bio);
      await cubit.bootstrap();
      await cubit.unlock('parola123'); // unlocked
      return cubit;
    }

    testWidgets('cihaz available → switch etkin, aç → enableBiometric', (
      tester,
    ) async {
      final storage = _FakeStorage();
      final bio = _FakeBiometric(available: true);
      final cubit = await unlockedCubit(storage, bio);

      await tester.pumpWidget(
        MaterialApp(
          home: BlocProvider.value(value: cubit, child: const SettingsPage()),
        ),
      );
      expect(find.byType(SwitchListTile), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(bio.enrollCount, 1);
      expect(cubit.state.biometricEnrolled, isTrue);
      await cubit.close();
    });

    testWidgets('enrolled DEĞİL + cihaz unavailable → switch devre dışı', (
      tester,
    ) async {
      final storage = _FakeStorage();
      final bio = _FakeBiometric(available: false);
      final cubit = await unlockedCubit(
        storage,
        bio,
      ); // bmk yok → enrolled false

      await tester.pumpWidget(
        MaterialApp(
          home: BlocProvider.value(value: cubit, child: const SettingsPage()),
        ),
      );
      final sw = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(
        sw.onChanged,
        isNull,
        reason: 'enrolled değil + cihaz uygun değil → açılamaz',
      );
      await cubit.close();
    });

    testWidgets('enrolled + cihaz unavailable → switch ETKİN, kapatılabilir '
        '(reviewer P2)', (tester) async {
      // Bmk'lı attrs + cihaz unavailable. unlock sonrası state:
      // enrolled=true, deviceBiometricAvailable=false.
      final storage = _FakeStorage();
      await KeyAttributesStore(storage: storage).write(_attrs(withBmk: true));
      final bio = _FakeBiometric(available: false);
      final cubit = _cubit(storage, bio);
      await cubit.bootstrap();
      await cubit.unlock('parola123');
      expect(cubit.state.biometricEnrolled, isTrue);
      expect(cubit.state.deviceBiometricAvailable, isFalse);

      await tester.pumpWidget(
        MaterialApp(
          home: BlocProvider.value(value: cubit, child: const SettingsPage()),
        ),
      );
      final sw = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(
        sw.onChanged,
        isNotNull,
        reason: 'enrolled iken cihaz uygun olmasa da KAPATILABİLMELİ',
      );

      // Kapat → disableBiometric (availability'den bağımsız).
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(bio.disableCount, 1);
      expect(cubit.state.biometricEnrolled, isFalse);
      await cubit.close();
    });
  });
}
