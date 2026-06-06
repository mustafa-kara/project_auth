/// Uygulama yönlendirmesi (go_router).
///
/// Faz 0/1: yalnızca vault ve tarama rotaları. Auth redirect guard'ı Faz 3'te
/// (Supabase oturumu) eklenecek — şimdilik iskelet [redirect] yorum olarak hazır.
library;

import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import '../../features/scan/presentation/scan_page.dart';
import '../../features/vault/presentation/pages/vault_page.dart';

abstract final class Routes {
  static const vault = '/';
  static const scan = '/scan';
  static const addManual = '/add';
}

final GoRouter appRouter = GoRouter(
  initialLocation: Routes.vault,
  // Route loglarını yalnızca debug build'de aç (profile/release'te sessiz).
  debugLogDiagnostics: kDebugMode,
  // Faz 3: refreshListenable: authRepository, redirect: _authGuard,
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
);
