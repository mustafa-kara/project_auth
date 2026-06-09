/// RestoreFailedPage widget testi (Faz 3 Patch 2, reviewer [P1] #2).
///
/// KRİTİK: bu ekranda parola/recovery/biyometri aksiyonu OLMAMALI (lokal attrs yok →
/// unlock/recover StateError atardı). Yalnız "Tekrar dene" (retryRestore) +
/// "Çıkış / hesap değiştir" (signOut). libsodium GEREKMEZ — cubit'ler subclass fake.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/features/account/data/pending_confirmation_store.dart';
import 'package:project_auth/features/account/domain/auth_repository.dart';
import 'package:project_auth/features/account/presentation/bloc/session_cubit.dart';
import 'package:project_auth/features/account/presentation/pages/restore_failed_page.dart';
import 'package:project_auth/features/auth/data/key_attributes_store.dart';
import 'package:project_auth/features/auth/domain/biometric_service.dart';
import 'package:project_auth/features/auth/domain/key_manager.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';

class _FakeStorage implements FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async => data[key];
  @override
  Future<void> write({required String key, required String? value, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async => data[key] = value ?? '';
  @override
  Future<void> delete({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async => data.remove(key);
  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

class _FakeAuth implements AuthRepository {
  @override
  AuthSessionState get current => AuthSessionState.signedOut;
  @override
  String? get currentUserId => null;
  @override
  Stream<AuthSessionState> authStateChanges() =>
      const Stream<AuthSessionState>.empty();
  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

/// signOut'u sayan SessionCubit (gerçek AuthRepository çağrısı yapmaz).
class _FakeSessionCubit extends SessionCubit {
  _FakeSessionCubit(FlutterSecureStorage storage)
      : super(
          auth: _FakeAuth(),
          pendingStore: PendingConfirmationStore(storage: storage),
        );
  int signOutCount = 0;
  @override
  Future<void> signOut() async => signOutCount++;
}

class _FakeBiometric implements BiometricService {
  @override
  Future<bool> isAvailable() async => false;
  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

/// retryRestore'u sayan VaultLockCubit; başlangıçta restoreFailed.
class _FakeLockCubit extends VaultLockCubit {
  _FakeLockCubit(FlutterSecureStorage storage)
      : super(
          keyManager: _NoKeyManager(),
          attrsStore: KeyAttributesStore(storage: storage), // dokunulmaz (retry override)
          biometric: _FakeBiometric(),
          migrate: (_) async {},
          deleteKeys: (_) async {},
        ) {
    emit(const VaultLockState.restoreFailed());
  }
  int retryCount = 0;
  @override
  Future<void> retryRestore() async => retryCount++;
}

class _NoKeyManager implements KeyManager {
  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

void main() {
  Widget pump(_FakeLockCubit lock, _FakeSessionCubit session) => MaterialApp(
        home: MultiBlocProvider(
          providers: [
            BlocProvider<VaultLockCubit>.value(value: lock),
            BlocProvider<SessionCubit>.value(value: session),
          ],
          child: const RestoreFailedPage(),
        ),
      );

  testWidgets('parola/recovery/biyometri aksiyonu YOK; yalnız retry + signOut',
      (tester) async {
    final storage = _FakeStorage();
    final lock = _FakeLockCubit(storage);
    final session = _FakeSessionCubit(storage);
    await tester.pumpWidget(pump(lock, session));

    // Parola alanı (TextField) bu ekranda OLMAMALI.
    expect(find.byType(TextField), findsNothing);
    // İki güvenli aksiyon var.
    expect(find.text('Tekrar dene'), findsOneWidget);
    expect(find.text('Çıkış yap / hesap değiştir'), findsOneWidget);

    await lock.close();
    await session.close();
  });

  testWidgets('"Tekrar dene" → retryRestore çağrılır', (tester) async {
    final storage = _FakeStorage();
    final lock = _FakeLockCubit(storage);
    final session = _FakeSessionCubit(storage);
    await tester.pumpWidget(pump(lock, session));

    await tester.tap(find.text('Tekrar dene'));
    await tester.pump();
    expect(lock.retryCount, 1);

    await lock.close();
    await session.close();
  });

  testWidgets('"Çıkış" → signOut çağrılır', (tester) async {
    final storage = _FakeStorage();
    final lock = _FakeLockCubit(storage);
    final session = _FakeSessionCubit(storage);
    await tester.pumpWidget(pump(lock, session));

    await tester.tap(find.text('Çıkış yap / hesap değiştir'));
    await tester.pump();
    expect(session.signOutCount, 1);

    await lock.close();
    await session.close();
  });
}
