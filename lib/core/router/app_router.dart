/// Uygulama yönlendirmesi (go_router) — Faz 2 Patch 4: kilit durumuna göre redirect.
///
/// Router artık **factory** ([createAppRouter]) ile kurulur çünkü `refreshListenable`
/// `VaultLockCubit`'in stream'ine bağlanır (Cubit doğrudan `Listenable` değil →
/// [CubitRefreshNotifier] adapter). Guard, [VaultLockCubit.state]'e göre yönlendirir.
///
/// **Sahiplik/dispose:** go_router refreshListenable'ı dispose ETMEZ → adapter'ı
/// kök widget tutar ve dispose eder ([AppRouterBundle]).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/bloc/vault_lock_cubit.dart';
import '../../features/auth/presentation/bloc/vault_lock_state.dart';
import '../../features/auth/presentation/pages/auth_integrity_page.dart';
import '../../features/auth/presentation/pages/recovery_show_page.dart';
import '../../features/auth/presentation/pages/recovery_unlock_page.dart';
import '../../features/auth/presentation/pages/recovery_verify_page.dart';
import '../../features/auth/presentation/pages/setup_password_page.dart';
import '../../features/auth/presentation/pages/unlock_page.dart';
import '../../features/scan/presentation/scan_page.dart';
import '../../features/vault/presentation/bloc/vault_cubit.dart';
import '../../features/vault/presentation/pages/vault_page.dart';
import 'cubit_refresh_notifier.dart';

abstract final class Routes {
  static const vault = '/';
  static const scan = '/scan';
  static const addManual = '/add';
  static const setup = '/setup';
  static const recoveryShow = '/setup/recovery';
  static const recoveryVerify = '/setup/verify';
  static const unlock = '/unlock';
  static const recovery = '/recovery';
  static const authIntegrity = '/auth-integrity';
}

/// Router + ona bağlı refresh notifier'ı birlikte taşıyan paket. Kök widget bunu
/// tutar ve `dispose()`'ta [refresh]'i kapatır (subscription sızıntısı önlenir).
class AppRouterBundle {
  final GoRouter router;
  final CubitRefreshNotifier refresh;
  const AppRouterBundle(this.router, this.refresh);
}

/// Unlocked subtree'de `VaultCubit`'i sağlayan builder — DI'dan masterKey'li
/// `EncryptedVaultRepository` ile kurar. (main/DI tarafından enjekte edilir.)
typedef VaultCubitBuilder = VaultCubit Function();

AppRouterBundle createAppRouter(
  VaultLockCubit lock, {
  required VaultCubitBuilder vaultCubitBuilder,
}) {
  final refresh = CubitRefreshNotifier(lock.stream);

  final router = GoRouter(
    initialLocation: Routes.vault,
    debugLogDiagnostics: kDebugMode,
    refreshListenable: refresh,
    redirect: (context, state) =>
        guardRedirect(lock.state, state.matchedLocation),
    routes: [
      // --- Unlocked subtree: VaultCubit yalnız burada sağlanır ---
      ShellRoute(
        builder: (context, state, child) => BlocProvider<VaultCubit>(
          create: (_) => vaultCubitBuilder()..load(),
          child: child,
        ),
        routes: [
          GoRoute(
            path: Routes.vault,
            name: 'vault',
            builder: (context, state) => const VaultPage(),
            routes: [
              GoRoute(
                path: 'scan',
                name: 'scan',
                builder: (context, state) => const ScanPage(),
              ),
            ],
          ),
        ],
      ),
      // --- Setup akışı ---
      GoRoute(
        path: Routes.setup,
        name: 'setup',
        builder: (context, state) => const SetupPasswordPage(),
        routes: [
          GoRoute(
            path: 'recovery',
            name: 'recoveryShow',
            builder: (context, state) => const RecoveryShowPage(),
          ),
          GoRoute(
            path: 'verify',
            name: 'recoveryVerify',
            builder: (context, state) => const RecoveryVerifyPage(),
          ),
        ],
      ),
      // --- Unlock / recovery ---
      GoRoute(
        path: Routes.unlock,
        name: 'unlock',
        builder: (context, state) => const UnlockPage(),
      ),
      GoRoute(
        path: Routes.recovery,
        name: 'recovery',
        builder: (context, state) => const RecoveryUnlockPage(),
      ),
      // --- Auth bütünlük hatası (attrs okunamadı) ---
      GoRoute(
        path: Routes.authIntegrity,
        name: 'authIntegrity',
        builder: (context, state) => const AuthIntegrityPage(),
      ),
    ],
  );

  return AppRouterBundle(router, refresh);
}

/// Kilit durumuna göre redirect. null = yönlendirme yok (mevcut konumda kal).
/// Saf fonksiyon → birim test edilebilir (router'ı kurmadan).
@visibleForTesting
String? guardRedirect(VaultLockState lock, String location) {
  switch (lock.status) {
    case VaultLockStatus.uninitialized:
      // Yalnız parola ekranı; recovery-show/verify alt rotaları setupPending'i
      // gerektirir (mnemonic henüz YOK → boş listede RangeError olurdu — review P1).
      return location == Routes.setup ? null : Routes.setup;
    case VaultLockStatus.setupPending:
      // setupPending: tüm setup alt-ağacına izin (mnemonic state'te dolu).
      // Verify ekranından /setup'a zıplatma yok.
      return location.startsWith(Routes.setup) ? null : Routes.setup;
    case VaultLockStatus.locked:
    case VaultLockStatus.locking:
      // locking: unlocked subtree teardown → /unlock. recovery ekranına izin ver.
      if (location == Routes.unlock || location == Routes.recovery) return null;
      return Routes.unlock;
    case VaultLockStatus.unlocked:
      // unlocked iken vault + scan'e izin; auth ekranlarından vault'a dön.
      if (location == Routes.vault || location == Routes.scan) return null;
      return Routes.vault;
    case VaultLockStatus.keyAttributesCorrupted:
      return location == Routes.authIntegrity ? null : Routes.authIntegrity;
  }
}
