/// Faz 3 Patch 3 — VaultPage sync göstergesi (AppBar) widget testleri.
///
/// VaultState.syncState'e göre doğru ikon/Semantics. Gerçek sync GEREKMEZ — state
/// doğrudan kurulur (fake VaultCubit).
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/di/locator.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/otp/otp_generator.dart';
import 'package:project_auth/features/account/domain/sync_exceptions.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/data/view_mode_store.dart';
import 'package:project_auth/features/vault/domain/token_sync_service.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';
import 'package:project_auth/features/vault/presentation/pages/vault_page.dart';

class _EmptyRepo implements VaultRepository {
  @override
  Future<VaultLoadResult> load() async => VaultLoadResult.empty;
  @override
  Future<void> save(List<OtpAccount> accounts) async {}
  @override
  Future<void> purgeCorrupted() async {}
}

/// State'i elle set edebilen VaultCubit (gösterge testleri için).
class _StateCubit extends VaultCubit {
  _StateCubit() : super(_EmptyRepo());
  void setSync(SyncState s) => emit(state.copyWith(loaded: true, syncState: s));
}

class _MemStorage implements FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async => data[key];
  @override
  Future<void> write({required String key, required String? value, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async {
    if (value == null) { data.remove(key); } else { data[key] = value; }
  }
  @override
  Future<void> delete({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async => data.remove(key);
  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

class _FakeLockCubit extends Cubit<VaultLockState> implements VaultLockCubit {
  _FakeLockCubit() : super(const VaultLockState.unlocked());
  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Future<void> _pump(WidgetTester tester, _StateCubit cubit) async {
  await tester.pumpWidget(MultiBlocProvider(
    providers: [
      BlocProvider<VaultCubit>.value(value: cubit),
      BlocProvider<VaultLockCubit>.value(value: _FakeLockCubit()),
    ],
    child: const MediaQuery(
      data: MediaQueryData(disableAnimations: true),
      child: MaterialApp(home: VaultPage()),
    ),
  ));
  await tester.pump();
}

void main() {
  setUp(() {
    if (!locator.isRegistered<OtpGenerator>()) {
      locator.registerLazySingleton<OtpGenerator>(() => const OtpGenerator());
    }
    if (!locator.isRegistered<ViewModeStore>()) {
      locator.registerLazySingleton<ViewModeStore>(
          () => ViewModeStore(storage: _MemStorage()));
    }
  });
  testWidgets('idle & temiz → gösterge yok', (tester) async {
    final cubit = _StateCubit()..setSync(SyncState.idle);
    await _pump(tester, cubit);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.sync_problem), findsNothing);
    expect(find.byIcon(Icons.warning_amber), findsNothing);
    await cubit.close();
  });

  testWidgets('syncing → dönen ikon + Semantics', (tester) async {
    final cubit = _StateCubit()..setSync(const SyncState(phase: SyncPhase.syncing));
    await _pump(tester, cubit);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.bySemanticsLabel('Senkronize ediliyor'), findsOneWidget);
    await cubit.close();
  });

  testWidgets('error → sync_problem ikonu', (tester) async {
    final cubit = _StateCubit()
      ..setSync(const SyncState(phase: SyncPhase.error, error: SyncNetworkError()));
    await _pump(tester, cubit);
    expect(find.byIcon(Icons.sync_problem), findsOneWidget);
    await cubit.close();
  });

  testWidgets('idle + malformedCount>0 → uyarı rozeti (ikon + sayı)',
      (tester) async {
    final cubit = _StateCubit()
      ..setSync(const SyncState(phase: SyncPhase.idle, malformedCount: 2));
    await _pump(tester, cubit);
    // StatusBadge (warning): sync_problem ikonu + malformed sayısı (color-not-only).
    expect(find.byIcon(Icons.sync_problem), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    await cubit.close();
  });
}
