/// Faz 5 Patch 1 — Settings "YEDEKLEME VE AKTARIM" bölümü widget testi.
///
/// Bölüm her zaman görünür (yerel bir yetenek; sunucu/servis gerektirmez) ve
/// iki ListTile ilgili rotaya götürür. Gerçek Import/Export sayfaları yerine
/// işaret widget'ları kullanılır → DI (locator) ve file_picker gerekmez.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:project_auth/core/router/app_router.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/settings/presentation/settings_page.dart';

class _FakeLockCubit extends Cubit<VaultLockState> implements VaultLockCubit {
  _FakeLockCubit()
    : super(
        VaultLockState.unlocked(
          biometricEnrolled: false,
          deviceBiometricAvailable: false,
        ),
      );
  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Widget _app(GoRouter router, VaultLockCubit lock) =>
    BlocProvider<VaultLockCubit>.value(
      value: lock,
      child: MaterialApp.router(routerConfig: router),
    );

GoRouter _router() => GoRouter(
  initialLocation: Routes.settings,
  routes: [
    GoRoute(path: Routes.settings, builder: (_, _) => const SettingsPage()),
    GoRoute(
      path: Routes.importData,
      builder: (_, _) => const Scaffold(body: Text('IMPORT-SAYFASI')),
    ),
    GoRoute(
      path: Routes.exportData,
      builder: (_, _) => const Scaffold(body: Text('EXPORT-SAYFASI')),
    ),
  ],
);

void main() {
  late VaultLockCubit lock;
  late GoRouter router;

  setUp(() {
    lock = _FakeLockCubit();
    router = _router();
  });

  tearDown(() {
    router.dispose();
    lock.close();
  });

  testWidgets('bölüm ve her iki giriş noktası görünür', (tester) async {
    await tester.pumpWidget(_app(router, lock));
    await tester.pumpAndSettle();

    expect(find.text('YEDEKLEME VE AKTARIM'), findsOneWidget);
    expect(find.text('İçe aktar'), findsOneWidget);
    expect(find.text('Şifreli yedek al'), findsOneWidget);
    expect(find.text('Aegis veya 2FAS yedeğinden token aktar'), findsOneWidget);
  });

  testWidgets('"İçe aktar" → /import rotası', (tester) async {
    await tester.pumpWidget(_app(router, lock));
    await tester.pumpAndSettle();

    await tester.tap(find.text('İçe aktar'));
    await tester.pumpAndSettle();

    expect(find.text('IMPORT-SAYFASI'), findsOneWidget);
  });

  testWidgets('"Şifreli yedek al" → /export rotası', (tester) async {
    await tester.pumpWidget(_app(router, lock));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Şifreli yedek al'));
    await tester.pumpAndSettle();

    expect(find.text('EXPORT-SAYFASI'), findsOneWidget);
  });
}
