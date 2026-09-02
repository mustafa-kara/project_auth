/// Router seviyesinde SecureScreen regresyon testi.
///
/// Vault ekranı [SecureScreenScope] ile sarılıdır. Üstüne `/settings` PUSH
/// edildiğinde VaultPage stack'te KALIR (dispose olmaz) → native tarafa `disable`
/// GİTMEMELİDİR. Naif initState→enable / dispose→disable kalıbı ya da sayaçsız
/// bir kurulum burada korumayı erken kapatırdı.
///
/// Gerçek [createAppRouter] kullanılır (guard + ShellRoute dahil); yalnız cubit'ler
/// ve store'lar fake — libsodium/Supabase GEREKMEZ.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/platform/secure_screen.dart';
import 'package:project_auth/core/router/app_router.dart';
import 'package:project_auth/features/account/presentation/bloc/session_cubit.dart';
import 'package:project_auth/features/account/presentation/bloc/session_state.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/vault/data/live_sync_pref_store.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/data/view_mode_store.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';

/// Sahte kilit cubit'i — vault AÇIK (guard vault/scan/settings'e izin verir).
class _FakeLock extends Cubit<VaultLockState> implements VaultLockCubit {
  _FakeLock()
    : super(
        VaultLockState.unlocked(
          biometricEnrolled: false,
          deviceBiometricAvailable: false,
        ),
      );
  @override
  noSuchMethod(Invocation i) {}
}

/// Sahte oturum cubit'i — signedIn (kimlik kapısı açık).
class _FakeSession extends Cubit<SessionState> implements SessionCubit {
  _FakeSession() : super(const SessionState(status: SessionStatus.signedIn));
  @override
  noSuchMethod(Invocation i) {}
}

/// Boş bellek-içi vault (secure_storage'a dokunmaz).
class _EmptyRepo implements VaultRepository {
  @override
  Future<VaultLoadResult> load() async => VaultLoadResult.empty;
  @override
  Future<void> save(List<OtpAccount> accounts) async {}
  @override
  Future<void> purgeCorrupted() async {}
}

class _MemStorage implements FlutterSecureStorage {
  final Map<String, String> _d = {};
  @override
  Future<String?> read({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async => _d[key];
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
      _d.remove(key);
    } else {
      _d[key] = value;
    }
  }

  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
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

  testWidgets('vault → /settings PUSH: koruma açık kalır (disable GELMEZ)', (
    tester,
  ) async {
    final lock = _FakeLock();
    final session = _FakeSession();
    addTearDown(lock.close);
    addTearDown(session.close);

    final bundle = createAppRouter(
      lock,
      session: session,
      vaultCubitBuilder: () => VaultCubit(_EmptyRepo()),
      viewModeStoreBuilder: () => ViewModeStore(storage: _MemStorage()),
      liveSyncStoreBuilder: () => LiveSyncPrefStore(storage: _MemStorage()),
    );
    addTearDown(bundle.dispose);

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<VaultLockCubit>.value(value: lock),
          BlocProvider<SessionCubit>.value(value: session),
        ],
        child: MaterialApp.router(routerConfig: bundle.router),
      ),
    );
    await tester.pumpAndSettle();

    // signedIn + unlocked → guard /splash'ten vault'a alır → SecureScreenScope mount.
    expect(calls, ['enable'], reason: 'vault mount → koruma açılmalı');
    expect(SecureScreen.holderCount, 1);

    // Üstüne /settings PUSH: VaultPage dispose OLMAZ → disable gitmemeli.
    bundle.router.push(Routes.settings);
    await tester.pumpAndSettle();
    expect(calls, [
      'enable',
    ], reason: '/settings push → disable ERKEN gelmemeli');

    // Geri dönüşte de değişmez (vault hâlâ tek tutucu).
    bundle.router.pop();
    await tester.pumpAndSettle();
    expect(calls, ['enable']);
    expect(SecureScreen.holderCount, 1);
  });
}
