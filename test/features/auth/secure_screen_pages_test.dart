/// Hassas auth ekranları SecureScreen korumasını AÇAR/KAPATIR.
///
/// Master parola (unlock/setup), recovery key (show/verify/unlock) ve hesap
/// parolası (login/register) ekranları [SecureScreenScope] ile sarılıdır →
/// mount'ta native `enable`, unmount'ta `disable`. libsodium GEREKMEZ (fake
/// cubit + mock MethodChannel).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/platform/secure_screen.dart';
import 'package:project_auth/features/account/presentation/bloc/session_cubit.dart';
import 'package:project_auth/features/account/presentation/bloc/session_state.dart';
import 'package:project_auth/features/account/presentation/pages/login_page.dart';
import 'package:project_auth/features/account/presentation/pages/register_page.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/auth/presentation/pages/recovery_show_page.dart';
import 'package:project_auth/features/auth/presentation/pages/recovery_unlock_page.dart';
import 'package:project_auth/features/auth/presentation/pages/recovery_verify_page.dart';
import 'package:project_auth/features/auth/presentation/pages/setup_password_page.dart';
import 'package:project_auth/features/auth/presentation/pages/unlock_page.dart';

/// Sahte cubit — state sabit, aksiyonlar no-op.
class _FakeLock extends Cubit<VaultLockState> implements VaultLockCubit {
  _FakeLock(super.state);
  @override
  noSuchMethod(Invocation i) {}
}

/// Sahte oturum cubit'i — login/register yalnız `state`'i okur.
class _FakeSession extends Cubit<SessionState> implements SessionCubit {
  _FakeSession(super.state);
  @override
  noSuchMethod(Invocation i) {}
}

void main() {
  const channel = MethodChannel('dev.mustafakara.project_auth/secure_screen');
  late List<String> calls;

  setUp(() {
    calls = [];
    SecureScreen.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    SecureScreen.debugReset();
  });

  /// Sayfayı mount → `enable`, unmount → `disable` beklenir.
  Future<void> expectProtected(
    WidgetTester tester, {
    required Widget page,
    required VaultLockState lockState,
  }) async {
    final lock = _FakeLock(lockState);
    addTearDown(lock.close);

    await tester.pumpWidget(MaterialApp(
      home: BlocProvider<VaultLockCubit>.value(value: lock, child: page),
    ));
    await tester.pump();
    expect(calls, ['enable'], reason: 'mount → koruma açılmalı');
    expect(SecureScreen.holderCount, 1);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(calls, ['enable', 'disable'], reason: 'unmount → koruma kapanmalı');
    expect(SecureScreen.holderCount, 0);
  }

  testWidgets('UnlockPage (master parola girişi) korunur', (tester) async {
    await expectProtected(
      tester,
      page: const UnlockPage(),
      lockState: const VaultLockState.locked(),
    );
  });

  testWidgets('SetupPasswordPage (yeni master parola) korunur', (tester) async {
    await expectProtected(
      tester,
      page: const SetupPasswordPage(),
      lockState: const VaultLockState.uninitialized(),
    );
  });

  testWidgets('RecoveryUnlockPage (24 kelime + yeni parola) korunur',
      (tester) async {
    await expectProtected(
      tester,
      page: const RecoveryUnlockPage(),
      lockState: const VaultLockState.locked(),
    );
  });

  testWidgets('RecoveryVerifyPage (recovery kelime girişi) korunur',
      (tester) async {
    await expectProtected(
      tester,
      page: const RecoveryVerifyPage(),
      lockState: VaultLockState.setupPending(
          mnemonic: List.generate(24, (i) => 'word$i')),
    );
  });

  testWidgets('RecoveryShowPage (24 kelime gösterimi) korunur', (tester) async {
    // Geniş viewport: 24-kelime grid tek ekranda sığsın (overflow → test hatası).
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await expectProtected(
      tester,
      page: const RecoveryShowPage(),
      lockState: VaultLockState.setupPending(
          mnemonic: List.generate(24, (i) => 'word$i')),
    );
  });

  /// Login/register (hesap parolası) — SessionCubit bağımlılığı ile aynı kontrol.
  Future<void> expectSessionPageProtected(
    WidgetTester tester, {
    required Widget page,
  }) async {
    final session = _FakeSession(const SessionState());
    addTearDown(session.close);

    await tester.pumpWidget(MaterialApp(
      home: BlocProvider<SessionCubit>.value(value: session, child: page),
    ));
    await tester.pump();
    expect(calls, ['enable'], reason: 'mount → koruma açılmalı');
    expect(SecureScreen.holderCount, 1);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(calls, ['enable', 'disable'], reason: 'unmount → koruma kapanmalı');
    expect(SecureScreen.holderCount, 0);
  }

  testWidgets('LoginPage (hesap parolası girişi) korunur', (tester) async {
    await expectSessionPageProtected(tester, page: const LoginPage());
  });

  testWidgets('RegisterPage (hesap parolası + tekrar) korunur', (tester) async {
    await expectSessionPageProtected(tester, page: const RegisterPage());
  });
}
