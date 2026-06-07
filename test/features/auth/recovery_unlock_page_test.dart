/// RecoveryUnlockPage — mnemonic giriş ayrıştırma davranışı.
///
/// Asıl kapsam: kullanıcı Show ekranının "Panoya kopyala"sının ürettiği
/// **numaralı** formatı ("1. lizard\n2. goddess ...") yapıştırırsa, sıra
/// numaraları ayıklanıp KeyManager.recoverUnlock'a TEMİZ 24 kelime ulaşmalı
/// (aksi halde token sayısı 48 olur, validasyon patlar). Düz boşluklu giriş de
/// çalışmaya devam eder. libsodium GEREKMEZ: KeyManager fake'lenir.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/core/crypto/key_attributes.dart';
import 'package:project_auth/core/crypto/key_handle.dart';
import 'package:project_auth/features/auth/data/key_attributes_store.dart';
import 'package:project_auth/features/auth/domain/biometric_service.dart';
import 'package:project_auth/features/auth/domain/key_manager.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/pages/recovery_unlock_page.dart';

class _FakeKeyHandle implements KeyHandle {
  @override
  void dispose() {}
}

/// Bu testler biyometriyle ilgilenmiyor → cihaz yok varsayımı (isAvailable false).
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

final _words = List.generate(24, (i) => 'word$i');

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

/// recoverUnlock'a gelen mnemonic'i yakalar; changePassword no-op döner.
class _CapturingKeyManager implements KeyManager {
  List<String>? capturedMnemonic;

  @override
  Future<KeyHandle> recoverUnlock(KeyAttributes attrs, List<String> mnemonic) async {
    capturedMnemonic = mnemonic;
    return _FakeKeyHandle();
  }

  @override
  Future<KeyAttributes> changePassword(
          KeyAttributes attrs, KeyHandle masterKey, String newPassword) async =>
      _attrs();

  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

void main() {
  late _CapturingKeyManager km;
  late VaultLockCubit cubit;

  setUp(() {
    km = _CapturingKeyManager();
    cubit = VaultLockCubit(
      keyManager: km,
      attrsStore: _FakeAttrsStore(_attrs()),
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
          child: const RecoveryUnlockPage(),
        ),
      ),
    );
  }

  testWidgets('numaralı yedek formatı yapıştırılırsa numaralar ayıklanır → '
      'temiz 24 kelime', (tester) async {
    await pump(tester);

    // Show ekranının "Panoya kopyala"sının ürettiği numaralı format.
    final numbered = [
      for (var i = 0; i < _words.length; i++) '${i + 1}. ${_words[i]}',
    ].join('\n');

    await tester.enterText(find.byType(TextField).first, numbered);
    await tester.enterText(find.byType(TextField).at(1), 'yeniparola123');
    await tester.tap(find.text('Aç ve yeni parolayı kaydet'));
    await tester.pump();
    await tester.pump();

    // KeyManager'a sıra numarası DEĞİL, sadece kelimeler ulaşmalı.
    expect(km.capturedMnemonic, _words);
  });

  testWidgets('düz boşluklu giriş de çalışır (regresyon)', (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField).first, _words.join(' '));
    await tester.enterText(find.byType(TextField).at(1), 'yeniparola123');
    await tester.tap(find.text('Aç ve yeni parolayı kaydet'));
    await tester.pump();
    await tester.pump();

    expect(km.capturedMnemonic, _words);
  });
}

/// attrsStore: locked state için dolu attrs döndürür (cubit bootstrap'i locked'a
/// koysun; recover akışı attrs'ı kullanır).
class _FakeAttrsStore implements KeyAttributesStore {
  final KeyAttributes _a;
  _FakeAttrsStore(this._a);
  @override
  Future<KeyAttributes?> read() async => _a;
  @override
  Future<void> write(KeyAttributes attrs) async {} // no-op (persist test dışı)
  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}
