/// Faz 3 Patch 3 — Settings canlı senkron toggle widget testi.
///
/// Toggle yalnız sync destekleniyorsa (VaultCubit.syncEnabled) görünür; aç/kapat
/// LiveSyncPrefStore'a yazar + VaultCubit.enableLiveSync/disableLiveSync çağırır.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/account/data/feature_flags_cache_store.dart';
import 'package:project_auth/features/account/domain/feature_flags_repository.dart';
import 'package:project_auth/features/account/domain/feature_flags_service.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/settings/presentation/settings_page.dart';
import 'package:project_auth/features/vault/data/last_sync_store.dart';
import 'package:project_auth/features/vault/data/live_sync_pref_store.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/domain/raw_token_record.dart';
import 'package:project_auth/features/vault/domain/remote_token_repository.dart';
import 'package:project_auth/features/vault/domain/token_sync_service.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';

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

class _EmptyRepo implements VaultRepository {
  @override
  Future<VaultLoadResult> load() async => VaultLoadResult.empty;
  @override
  Future<void> save(List<OtpAccount> accounts) async {}
  @override
  Future<void> purgeCorrupted() async {}
}

class _FakeRawStore implements RawTokenStore {
  @override
  Future<List<RawTokenRecord>> exportRaw() async => const [];
  @override
  Future<TokenMergeOutcome> importRemote(List<RemoteTokenRow> remote,
          {required String? pullCursorIso}) async =>
      TokenMergeOutcome.none;
  @override
  Future<void> markDeleted(String id) async {}
}

class _FakeRemote implements RemoteTokenRepository {
  int subscribeCount = 0;
  int unsubscribeCount = 0;
  @override
  Future<RemotePullResult> pullSince(String uid, String? sinceIso) async =>
      const RemotePullResult(rows: []);
  @override
  Future<void> pushUpsert(String uid, List<RawTokenRecord> records) async {}
  @override
  RealtimeChannelHandle subscribe(String uid, void Function() onChange) {
    subscribeCount++;
    return _Handle(this);
  }
}

class _Handle implements RealtimeChannelHandle {
  _Handle(this.r);
  final _FakeRemote r;
  @override
  Future<void> unsubscribe() async => r.unsubscribeCount++;
}

class _FakeLockCubit extends Cubit<VaultLockState> implements VaultLockCubit {
  _FakeLockCubit() : super(VaultLockState.unlocked(
            biometricEnrolled: false, deviceBiometricAvailable: false));
  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// token_sync_enabled değerini test kontrol eder (refresh sonrası servis belleğine yansır).
class _FakeFlagsRepo implements FeatureFlagsRepository {
  bool enabled = true;
  @override
  Future<List<FeatureFlag>> fetchAll() async =>
      [FeatureFlag(key: 'token_sync_enabled', enabled: enabled)];
}

void main() {
  testWidgets('sync destekleniyor → Canlı senkron toggle görünür, açınca store+subscribe',
      (tester) async {
    final storage = _MemStorage();
    final liveStore = LiveSyncPrefStore(storage: storage);
    final remote = _FakeRemote();
    late VaultCubit vault;
    final sync = TokenSyncService(
      remote: remote,
      store: _FakeRawStore(),
      lastSync: LastSyncStore(storage: storage),
      uid: 'u1',
      mergeRemote: (rows, cursor) async => TokenMergeOutcome.none,
      onStatus: (_) {},
    );
    vault = VaultCubit(_EmptyRepo(), sync: sync, rawStore: _FakeRawStore());

    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<VaultCubit>.value(value: vault),
        BlocProvider<VaultLockCubit>.value(value: _FakeLockCubit()),
      ],
      child: RepositoryProvider<LiveSyncPrefStore>.value(
        value: liveStore,
        child: const MaterialApp(home: SettingsPage()),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Canlı senkron'), findsOneWidget);
    // Aç.
    await tester.tap(find.byType(SwitchListTile).last);
    await tester.pumpAndSettle();
    expect(await liveStore.read(), isTrue, reason: 'tercih persist edildi');
    expect(remote.subscribeCount, 1, reason: 'enableLive → subscribe');

    await vault.close();
  });

  testWidgets('token_sync_enabled false olunca toggle REAKTİF gizlenir (review [P2])',
      (tester) async {
    final storage = _MemStorage();
    final liveStore = LiveSyncPrefStore(storage: storage);
    await liveStore.write(true);
    final remote = _FakeRemote();
    late VaultCubit vault;
    final flagsRepo = _FakeFlagsRepo();
    final flags = FeatureFlagsService(
      repo: flagsRepo,
      cache: FeatureFlagsCacheStore(storage: _MemStorage()),
    );
    final sync = TokenSyncService(
      remote: remote,
      store: _FakeRawStore(),
      lastSync: LastSyncStore(storage: storage),
      uid: 'u1',
      mergeRemote: (rows, cursor) async => TokenMergeOutcome.none,
      onStatus: (_) {},
      isEnabled: () => flags.isEnabled('token_sync_enabled', fallback: true),
      flagListenable: flags.listenable,
    );
    vault = VaultCubit(
      _EmptyRepo(),
      sync: sync,
      rawStore: _FakeRawStore(),
      tokenSyncEnabled: () => flags.isEnabled('token_sync_enabled', fallback: true),
    );

    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<VaultCubit>.value(value: vault),
        BlocProvider<VaultLockCubit>.value(value: _FakeLockCubit()),
      ],
      child: MultiRepositoryProvider(
        providers: [
          RepositoryProvider<LiveSyncPrefStore>.value(value: liveStore),
          RepositoryProvider<FeatureFlagsService>.value(value: flags),
        ],
        child: const MaterialApp(home: SettingsPage()),
      ),
    ));
    await tester.pumpAndSettle();
    // Flag fallback=true (henüz refresh yok) → toggle görünür.
    expect(find.text('Canlı senkron'), findsOneWidget);

    // Server token_sync_enabled=false → refresh → listenable notify → REAKTİF gizlenir.
    flagsRepo.enabled = false;
    await flags.refresh();
    await tester.pumpAndSettle();
    expect(find.text('Canlı senkron'), findsNothing,
        reason: 'flag false → toggle reaktif gizlendi');

    await vault.close();
  });

  testWidgets('sync desteklenmiyor (uid yok) → toggle GİZLİ', (tester) async {
    final storage = _MemStorage();
    final vault = VaultCubit(_EmptyRepo()); // sync yok
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<VaultCubit>.value(value: vault),
        BlocProvider<VaultLockCubit>.value(value: _FakeLockCubit()),
      ],
      child: RepositoryProvider<LiveSyncPrefStore>.value(
        value: LiveSyncPrefStore(storage: storage),
        child: const MaterialApp(home: SettingsPage()),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Canlı senkron'), findsNothing);
    await vault.close();
  });
}
