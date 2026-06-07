/// RecoveryVerifyPage — deneme limiti davranışı (review #4 + kullanıcı kararı:
/// N=3 deneme, sonra cancelSetup). libsodium GEREKMEZ: KeyManager fake'lenir.
///
/// - 1 yanlış deneme → inline hata, setupPending KALIR (pending key dispose olmaz).
/// - 3. yanlış deneme → cancelSetup() → uninitialized, pending masterKey dispose.
/// - doğru kelimeler → commitSetup() → unlocked.
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
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/auth/presentation/pages/recovery_verify_page.dart';

class _FakeStorage implements FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async =>
      data[key];
  @override
  Future<void> write({required String key, required String? value, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async =>
      data.remove(key);
  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

class _FakeKeyHandle implements KeyHandle {
  bool disposed = false;
  @override
  void dispose() => disposed = true;
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

class _FakeKeyManager implements KeyManager {
  final List<_FakeKeyHandle> issued = [];
  final List<String> mnemonic = List.generate(24, (i) => 'word$i');
  @override
  Future<SetupResult> setup(String p) async {
    final k = _FakeKeyHandle();
    issued.add(k);
    return (attrs: _attrs(), recoveryMnemonic: mnemonic, masterKey: k);
  }

  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

/// Bu testler biyometriyle ilgilenmiyor → cihaz yok varsayımı.
class _NoBiometric implements BiometricService {
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<void> enroll(Uint8List keyBytes) async {}
  @override
  Future<Uint8List> retrieve() async => Uint8List(0);
  @override
  Future<void> disable() async {}
}

void main() {
  late _FakeKeyManager km;
  late VaultLockCubit cubit;

  setUp(() {
    km = _FakeKeyManager();
    final storage = _FakeStorage();
    cubit = VaultLockCubit(
      keyManager: km,
      attrsStore: KeyAttributesStore(storage: storage),
      biometric: _NoBiometric(),
      migrate: (_) async {},
      deleteKeys: (_) async {},
    );
  });

  tearDown(() => cubit.close());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider.value(
          value: cubit,
          child: const RecoveryVerifyPage(),
        ),
      ),
    );
  }

  Future<void> enterWords(WidgetTester tester, List<String> words) async {
    final fields = find.byType(TextField);
    for (var i = 0; i < words.length; i++) {
      await tester.enterText(fields.at(i), words[i]);
    }
  }

  testWidgets('1 yanlış deneme → inline hata, setupPending KALIR', (tester) async {
    await cubit.beginSetup('parola123');
    await pump(tester);

    await enterWords(tester, ['x', 'y', 'z']); // hepsi yanlış
    await tester.tap(find.text('Kurulumu tamamla'));
    await tester.pump();

    expect(find.textContaining('deneme hakkın kaldı'), findsOneWidget);
    expect(cubit.state.status, VaultLockStatus.setupPending);
    expect(km.issued.single.disposed, isFalse); // pending key canlı
  });

  testWidgets('3 yanlış deneme → cancelSetup → uninitialized + dispose',
      (tester) async {
    await cubit.beginSetup('parola123');
    await pump(tester);

    for (var attempt = 0; attempt < 3; attempt++) {
      await enterWords(tester, ['x', 'y', 'z']);
      await tester.tap(find.text('Kurulumu tamamla'));
      await tester.pump();
    }

    expect(cubit.state.status, VaultLockStatus.uninitialized);
    expect(km.issued.single.disposed, isTrue); // pending key dispose edildi
  });

  testWidgets('doğru kelimeler → commitSetup → unlocked', (tester) async {
    await cubit.beginSetup('parola123');
    await pump(tester);

    // _positions = [2, 9, 17] → mnemonic[2/9/17].
    await enterWords(tester, ['word2', 'word9', 'word17']);
    await tester.tap(find.text('Kurulumu tamamla'));
    await tester.pump(); // _verify başlar (_busy=true)
    await tester.pump(); // commitSetup future tamamlanır → unlocked

    expect(cubit.state.status, VaultLockStatus.unlocked);
  });
}
