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

import '../../features/account/presentation/bloc/session_cubit.dart';
import '../../features/account/presentation/bloc/session_state.dart';
import '../../features/account/presentation/pages/account_link_page.dart';
import '../../features/account/presentation/pages/email_confirm_pending_page.dart';
import '../../features/account/presentation/pages/login_page.dart';
import '../../features/account/presentation/pages/register_page.dart';
import '../../features/account/presentation/pages/splash_page.dart';
import '../../features/auth/presentation/bloc/vault_lock_cubit.dart';
import '../../features/auth/presentation/bloc/vault_lock_state.dart';
import '../../features/auth/presentation/pages/auth_integrity_page.dart';
import '../../features/auth/presentation/pages/recovery_show_page.dart';
import '../../features/auth/presentation/pages/recovery_unlock_page.dart';
import '../../features/auth/presentation/pages/recovery_verify_page.dart';
import '../../features/auth/presentation/pages/setup_password_page.dart';
import '../../features/auth/presentation/pages/unlock_page.dart';
import '../../features/scan/presentation/scan_page.dart';
import '../../features/settings/presentation/settings_page.dart';
import '../../features/vault/data/view_mode_store.dart';
import '../../features/vault/presentation/bloc/vault_cubit.dart';
import '../../features/vault/presentation/pages/vault_page.dart';
import 'cubit_refresh_notifier.dart';

abstract final class Routes {
  static const splash = '/splash';
  static const vault = '/';
  static const scan = '/scan';
  static const addManual = '/add';
  static const settings = '/settings';
  static const setup = '/setup';
  static const recoveryShow = '/setup/recovery';
  static const recoveryVerify = '/setup/verify';
  static const unlock = '/unlock';
  static const recovery = '/recovery';
  static const authIntegrity = '/auth-integrity';
  // Faz 3 Patch 1 — kimlik (Supabase) kapısı (vault ShellRoute DIŞINDA).
  static const auth = '/auth';
  static const authLogin = '/auth/login';
  static const authRegister = '/auth/register';
  static const authConfirm = '/auth/confirm';
  static const authLink = '/auth/link';
}

/// Router + ona bağlı refresh notifier'ları birlikte taşıyan paket. Kök widget bunu
/// tutar ve `dispose()`'ta [refreshNotifiers]'ın HEPSİNİ kapatır (subscription
/// sızıntısı önlenir — reviewer [P2]: merge subscription sahibi DEĞİL).
class AppRouterBundle {
  final GoRouter router;
  final List<CubitRefreshNotifier> refreshNotifiers;
  const AppRouterBundle(this.router, this.refreshNotifiers);

  /// Tüm notifier'ları dispose eder (kök widget `dispose`'ta çağırır).
  void dispose() {
    for (final n in refreshNotifiers) {
      n.dispose();
    }
  }
}

/// Unlocked subtree'de `VaultCubit`'i sağlayan builder — DI'dan masterKey'li
/// `EncryptedVaultRepository` ile kurar. (main/DI tarafından enjekte edilir.)
typedef VaultCubitBuilder = VaultCubit Function();

/// Unlocked subtree'ye verilecek (aktif uid namespace'li) `ViewModeStore` builder'ı
/// (reviewer [P3] — global singleton yerine per-uid). main tarafından enjekte edilir.
typedef ViewModeStoreBuilder = ViewModeStore Function();

AppRouterBundle createAppRouter(
  VaultLockCubit lock, {
  required SessionCubit session,
  required VaultCubitBuilder vaultCubitBuilder,
  required ViewModeStoreBuilder viewModeStoreBuilder,
}) {
  // İKİ AYRI notifier (lock + session) → merge yalnız dinler, sahibi değil.
  // Bundle her ikisini de tutar + dispose eder (reviewer [P2]).
  final lockRefresh = CubitRefreshNotifier(lock.stream);
  final sessionRefresh = CubitRefreshNotifier(session.stream);
  final refresh = Listenable.merge([lockRefresh, sessionRefresh]);

  final router = GoRouter(
    initialLocation: Routes.splash,
    debugLogDiagnostics: kDebugMode,
    refreshListenable: refresh,
    redirect: (context, state) =>
        sessionGuard(session.state, lock.state, state.matchedLocation),
    routes: [
      // --- Splash (unknown boyunca; vault shell DIŞINDA — reviewer [P1]) ---
      GoRoute(
        path: Routes.splash,
        name: 'splash',
        builder: (context, state) => const SplashPage(),
      ),
      // --- Kimlik (Supabase) ekranları: vault ShellRoute DIŞINDA ---
      GoRoute(
        path: Routes.authLogin,
        name: 'authLogin',
        builder: (context, state) => const LoginPage(),
      ),
      GoRoute(
        path: Routes.authRegister,
        name: 'authRegister',
        builder: (context, state) => const RegisterPage(),
      ),
      GoRoute(
        path: Routes.authConfirm,
        name: 'authConfirm',
        builder: (context, state) => const EmailConfirmPendingPage(),
      ),
      GoRoute(
        path: Routes.authLink,
        name: 'authLink',
        builder: (context, state) => const AccountLinkPage(),
      ),
      // --- Unlocked subtree: VaultCubit + (per-uid) ViewModeStore yalnız burada ---
      ShellRoute(
        builder: (context, state, child) =>
            // Aktif uid namespace'li ViewModeStore (reviewer [P3]) → VaultPage
            // global singleton yerine bunu okur (per-uid kart/liste tercihi).
            RepositoryProvider<ViewModeStore>(
          create: (_) => viewModeStoreBuilder(),
          child: BlocProvider<VaultCubit>(
            create: (_) => vaultCubitBuilder()..load(),
            child: child,
          ),
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
              GoRoute(
                path: 'settings',
                name: 'settings',
                builder: (context, state) => const SettingsPage(),
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

  return AppRouterBundle(router, [lockRefresh, sessionRefresh]);
}

/// Birleşik guard (Faz 3 Patch 1): kimlik kapısı (Supabase oturum) EN DIŞTA, vault
/// guard yalnız `signedIn && !linkRequired` dalında. Saf fonksiyon → test edilebilir.
///
/// SIRA kritik (reviewer [P1]/[P2]):
/// - `unknown` → `/splash` (vault shell'e GİRMEZ; `masterKey` crash'i yok).
/// - `signedOut` → yalnız PUBLIC auth rotaları serbest; `/auth/link` YASAK.
/// - `emailConfirmPending` → `/auth/confirm` (trap; çıkış "Farklı e-posta" ile).
/// - `signedIn` → ÖNCE `linkRequired` (→ `/auth/link`), SONRA vault guard.
@visibleForTesting
String? sessionGuard(
    SessionState session, VaultLockState lock, String location) {
  final isPublicAuthRoute = location == Routes.authLogin ||
      location == Routes.authRegister ||
      location == Routes.authConfirm ||
      location == Routes.auth;
  final isAuthRoute = location.startsWith(Routes.auth); // /auth/link dahil

  switch (session.status) {
    case SessionStatus.unknown:
      return location == Routes.splash ? null : Routes.splash;
    case SessionStatus.signedOut:
      // /auth/link signed-out'ta PUBLIC değil → login'e (reviewer [P2]).
      return isPublicAuthRoute ? null : Routes.authLogin;
    case SessionStatus.emailConfirmPending:
      return location == Routes.authConfirm ? null : Routes.authConfirm;
    case SessionStatus.signedIn:
      // 1) Account-linking ÖNCE (/auth/link de isAuthRoute → bypass'ı önle).
      if (session.linkRequired) {
        return location == Routes.authLink ? null : Routes.authLink;
      }
      // 2) Sonra vault guard (masterKey gerektiren shell yalnız buradan sonra).
      // splash/auth rotasındaysak vault giriş noktasına git: lock'un istediği yer
      // (uninitialized→/setup, locked→/unlock, unlocked→/). `guardRedirect(.., vault)`
      // null dönerse (unlocked → vault zaten doğru) açıkça `/`'a yönlendir (kullanıcı
      // hâlâ /auth/login'de olduğu için orada KALMAMALI).
      if (location == Routes.splash || isAuthRoute) {
        return guardRedirect(lock, Routes.vault) ?? Routes.vault;
      }
      return guardRedirect(lock, location);
  }
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
      // unlocked iken vault + scan + settings'e izin; auth ekranlarından vault'a dön.
      if (location == Routes.vault ||
          location == Routes.scan ||
          location == Routes.settings) {
        return null;
      }
      return Routes.vault;
    case VaultLockStatus.keyAttributesCorrupted:
      return location == Routes.authIntegrity ? null : Routes.authIntegrity;
  }
}
