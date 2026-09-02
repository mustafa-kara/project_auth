/// VaultCubit + TokenSyncService entegrasyon testleri (Faz 3 Patch 3).
///
/// push-on-save, soft-delete (markDeleted) vs legacy hard-remove, reloadFromStore,
/// syncState yansıması. `sync=null` regresyonu mevcut vault_cubit_test'te.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/account/domain/sync_exceptions.dart';
import 'package:project_auth/features/vault/data/last_sync_store.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/domain/raw_token_record.dart';
import 'package:project_auth/features/vault/domain/remote_token_repository.dart';
import 'package:project_auth/features/vault/domain/token_sync_service.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';

import 'token_sync_service_test.dart' show FakeSecureStorage;

OtpAccount _acc(String name) =>
    OtpAccount(secret: 'JBSWY3DPEHPK3PXP', type: OtpType.totp, accountName: name);

EncryptedBlob _blob() =>
    EncryptedBlob(nonce: Uint8List(24), ciphertext: Uint8List(16));

class _FakeRepo implements VaultRepository {
  List<OtpAccount> stored;
  int saveCount = 0;
  _FakeRepo(this.stored);
  @override
  Future<VaultLoadResult> load() async => VaultLoadResult(accounts: List.of(stored));
  @override
  Future<void> save(List<OtpAccount> accounts) async {
    saveCount++;
    stored = List.of(accounts);
  }
  @override
  Future<void> purgeCorrupted() async {}
}

class _FakeRawStore implements RawTokenStore {
  int markDeletedCount = 0;
  String? lastDeletedId;

  /// pushChanged'in göndereceği dirty kayıtlar (test kontrol eder).
  List<RawTokenRecord> dirty = const [];

  int importCount = 0;
  String? lastImportCursor;
  TokenMergeOutcome importResult = TokenMergeOutcome.none;

  @override
  Future<List<RawTokenRecord>> exportRaw() async => dirty;
  @override
  Future<TokenMergeOutcome> importRemote(List<RemoteTokenRow> remote,
      {required String? pullCursorIso}) async {
    importCount++;
    lastImportCursor = pullCursorIso;
    return importResult;
  }
  @override
  Future<void> markDeleted(String id) async {
    markDeletedCount++;
    lastDeletedId = id;
  }
}

/// Push'u sayan ama ağ yapmayan minimal RemoteTokenRepository.
class _FakeRemote implements RemoteTokenRepository {
  int pushCount = 0;
  int subscribeCount = 0;
  int pullCount = 0;
  @override
  Future<RemotePullResult> pullSince(String uid, String? sinceIso) async {
    pullCount++;
    return const RemotePullResult(rows: []);
  }
  /// A4: açık tutulursa push "uçuşta" kalır (kilit tutulur).
  Completer<void>? pushGate;

  @override
  Future<void> pushUpsert(String uid, List<RawTokenRecord> records) async {
    pushCount++;
    final gate = pushGate;
    if (gate != null) await gate.future;
  }
  @override
  RealtimeChannelHandle subscribe(String uid, void Function() onChange) {
    subscribeCount++;
    return _NoopHandle();
  }
  @override
  Future<void> tombstoneAllRemote(String uid) async {}
  @override
  Future<void> tombstoneAllRemoteBefore(String uid, String beforeIso) async {}
}

class _NoopHandle implements RealtimeChannelHandle {
  @override
  Future<void> unsubscribe() async {}
}

void main() {
  late _FakeRepo repo;
  late _FakeRawStore rawStore;
  late _FakeRemote remote;
  late VaultCubit cubit;

  // sync alanını ctor'da bağlamak için (closure cubit'e ihtiyaç duyar).
  VaultCubit buildWithSync({List<OtpAccount>? seed}) {
    repo = _FakeRepo(seed ?? []);
    rawStore = _FakeRawStore();
    remote = _FakeRemote();
    late VaultCubit c;
    final s = TokenSyncService(
      remote: remote,
      store: rawStore,
      lastSync: LastSyncStore(storage: FakeSecureStorage()),
      uid: 'u1',
      mergeRemote: (rows, cursor) => c.applyRemoteMerge(rows, cursor),
      onStatus: (st) => c.updateSyncState(st),
    );
    c = VaultCubit(repo, rawStore: rawStore, sync: s);
    return c;
  }

  test('add → pushChanged tetiklenir (best-effort)', () async {
    cubit = buildWithSync();
    await cubit.load();
    // add sonrası store'da dirty kayıt oluşur (gerçek repo'da save sv=null yapar).
    rawStore.dirty = [
      RawTokenRecord(
          id: 'new', blob: _blob(), updatedAtMs: 1, serverUpdatedAtIso: null),
    ];
    await cubit.add(_acc('a'));
    await Future<void>.delayed(Duration.zero); // unawaited push tamamlansın
    expect(remote.pushCount, greaterThanOrEqualTo(1));
    expect(repo.saveCount, 1);
  });

  /// `load()` sonrası `sync.start` kendi ilk turunu (pull + push) unawaited
  /// çalıştırır → sayaç ölçümleri DELTA ile yapılır. Bu helper o turu boşaltır.
  Future<void> drain() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('addAll → TEK save + TEK pushChanged (N token için N push DEĞİL)',
      () async {
    cubit = buildWithSync();
    await cubit.load();
    await drain(); // start()'ın ilk turu bitsin → temiz taban
    final pushBefore = remote.pushCount;
    final saveBefore = repo.saveCount;

    rawStore.dirty = [
      RawTokenRecord(
          id: 'new', blob: _blob(), updatedAtMs: 1, serverUpdatedAtIso: null),
    ];
    await cubit.addAll([_acc('a'), _acc('b'), _acc('c')]);
    await drain();

    expect(repo.saveCount - saveBefore, 1, reason: '3 token → tek persist');
    expect(remote.pushCount - pushBefore, 1,
        reason: '3 token → tek push (batched)');
    expect(cubit.state.accounts.length, 3);
  });

  test('addAll boş liste → save da push da YOK', () async {
    cubit = buildWithSync();
    await cubit.load();
    await drain();
    final pushBefore = remote.pushCount;
    final saveBefore = repo.saveCount;

    rawStore.dirty = [
      RawTokenRecord(
          id: 'new', blob: _blob(), updatedAtMs: 1, serverUpdatedAtIso: null),
    ];
    await cubit.addAll(const []);
    await drain();

    expect(repo.saveCount, saveBefore);
    expect(remote.pushCount, pushBefore);
  });

  test('removeById → soft-delete (markDeleted), hard-remove DEĞİL', () async {
    cubit = buildWithSync(seed: [_acc('a')]);
    await cubit.load();
    final id = cubit.state.accounts.single.id;
    await cubit.removeById(id);
    await Future<void>.delayed(Duration.zero);
    expect(rawStore.markDeletedCount, 1);
    expect(rawStore.lastDeletedId, id);
    // sync'li yolda VaultRepository.save ÇAĞRILMAZ (markDeleted atomik yazar).
    expect(repo.saveCount, 0);
    expect(cubit.state.accounts, isEmpty);
  });

  test('removeById bilinmeyen id → no-op (markDeleted çağrılmaz)', () async {
    cubit = buildWithSync(seed: [_acc('a')]);
    await cubit.load();
    await cubit.removeById('yok');
    await Future<void>.delayed(Duration.zero);
    expect(rawStore.markDeletedCount, 0);
    expect(cubit.state.accounts.length, 1);
  });

  test('onMergedChanged → reloadFromStore → state diskten güncellenir', () async {
    cubit = buildWithSync(seed: [_acc('a')]);
    await cubit.load();
    expect(cubit.state.accounts.length, 1);
    // Disk "başka cihazdan" ikinci token kazandı (repo'yu doğrudan güncelle).
    repo.stored = [_acc('a'), _acc('b')];
    await cubit.reloadFromStore();
    expect(cubit.state.accounts.length, 2);
  });

  test('updateSyncState → state.syncState yansır (phase + malformedCount)', () async {
    cubit = buildWithSync();
    await cubit.load();
    cubit.updateSyncState(const SyncState(phase: SyncPhase.syncing));
    expect(cubit.state.syncState.phase, SyncPhase.syncing);
    cubit.updateSyncState(
        const SyncState(phase: SyncPhase.idle, malformedCount: 3));
    expect(cubit.state.syncState.malformedCount, 3);
    cubit.updateSyncState(
        const SyncState(phase: SyncPhase.error, error: SyncNetworkError()));
    expect(cubit.state.syncState.phase, SyncPhase.error);
  });

  test('reloadFromStore ilk load bitmeden ÇALIŞMAZ', () async {
    cubit = buildWithSync(seed: [_acc('a')]);
    // load() çağırmadan reload → no-op (state.loaded false kalır).
    await cubit.reloadFromStore();
    expect(cubit.state.loaded, isFalse);
  });

  test('reload-vs-mutation serileşir (sequencer)', () async {
    cubit = buildWithSync(seed: [_acc('a')]);
    await cubit.load();
    // Eşzamanlı: add + reload — sequencer sıraya alır, ikisi de tutarlı uygulanır.
    final f1 = cubit.add(_acc('b'));
    final f2 = cubit.reloadFromStore();
    await Future.wait([f1, f2]);
    // add diske yazıldı; reload diski okudu → en az 'a' + (add edilen) görünür.
    expect(cubit.state.accounts.any((a) => a.accountName == 'a'), isTrue);
  });

  test('applyRemoteMerge: importRemote (pullCursor ile) + changed → reload (reviewer [P1])',
      () async {
    cubit = buildWithSync(seed: [_acc('a')]);
    await cubit.load();
    for (var i = 0; i < 10; i++) { await Future<void>.delayed(Duration.zero); } // auto-start zinciri tamamlansın
    rawStore.importCount = 0; // auto-start'ın import'unu sıfırla → yalnız aşağıyı ölç
    rawStore.importResult = const TokenMergeOutcome(changed: true, appliedCount: 1);
    repo.stored = [_acc('a'), _acc('b')]; // import "diske" ikinci token yazmış gibi
    final outcome = await cubit.applyRemoteMerge(const [], '2026-06-09T09:00:00Z');
    expect(rawStore.importCount, 1);
    expect(rawStore.lastImportCursor, '2026-06-09T09:00:00Z');
    expect(outcome, isNotNull, reason: 'merge çalıştı → non-null');
    expect(outcome!.changed, isTrue);
    expect(cubit.state.accounts.length, 2, reason: 'changed → reload state\'i güncelledi');
  });

  test('applyRemoteMerge: vault kapalıysa null döner (cursor ilerletilmemeli — reviewer [P1])',
      () async {
    cubit = buildWithSync(seed: [_acc('a')]);
    await cubit.load();
    await cubit.close(); // vault kapandı
    final outcome = await cubit.applyRemoteMerge(
        const [], '2026-06-09T09:00:00Z');
    expect(outcome, isNull, reason: 'kapalı → merge yapılamadı → null (cursor ilerlemez)');
  });

  test('applyRemoteMerge ile kullanıcı mutasyonu TEK kuyrukta serileşir (reviewer [P1])',
      () async {
    cubit = buildWithSync(seed: [_acc('a')]);
    await cubit.load();
    for (var i = 0; i < 10; i++) { await Future<void>.delayed(Duration.zero); } // auto-start tamamlansın
    rawStore.importCount = 0;
    rawStore.importResult = const TokenMergeOutcome(changed: false, appliedCount: 0);
    // Eşzamanlı: add (sequencer) + applyRemoteMerge (sequencer) — yarış yok, ikisi de uygulanır.
    final f1 = cubit.add(_acc('b'));
    final f2 = cubit.applyRemoteMerge(const [], null);
    await Future.wait([f1, f2]);
    expect(rawStore.importCount, 1);
    expect(cubit.state.accounts.any((a) => a.accountName == 'b'), isTrue,
        reason: 'add merge tarafından ezilmedi');
  });

  test('persisted live=true → unlock başlangıcında subscribe (reviewer [P2] race yok)',
      () async {
    cubit = buildWithSync();
    cubit.liveSyncResolver = () async => true; // kayıtlı tercih AÇIK (async)
    await cubit.load(); // load() resolver'ı start'tan ÖNCE await eder
    await Future<void>.delayed(Duration.zero);
    expect(remote.subscribeCount, 1, reason: 'live=true → start(live:true) → subscribe');
  });

  test('persisted live=false → unlock başlangıcında subscribe YOK', () async {
    cubit = buildWithSync();
    cubit.liveSyncResolver = () async => false;
    await cubit.load();
    await Future<void>.delayed(Duration.zero);
    expect(remote.subscribeCount, 0);
  });

  // ── Faz 3 Patch 4 (Adım F) — VaultCubit kill-switch (start-gating) ───────────
  group('token_sync_enabled kill-switch (VaultCubit)', () {
    VaultCubit buildWithFlag({
      required bool flagEnabled,
      bool ensureCalledFirst = true,
    }) {
      repo = _FakeRepo([]);
      rawStore = _FakeRawStore();
      remote = _FakeRemote();
      var ensured = false;
      late VaultCubit c;
      final s = TokenSyncService(
        remote: remote,
        store: rawStore,
        lastSync: LastSyncStore(storage: FakeSecureStorage()),
        uid: 'u1',
        mergeRemote: (rows, cursor) => c.applyRemoteMerge(rows, cursor),
        onStatus: (st) => c.updateSyncState(st),
        isEnabled: () => flagEnabled,
      );
      c = VaultCubit(
        repo,
        rawStore: rawStore,
        sync: s,
        tokenSyncEnabled: () => flagEnabled,
        ensureTokenSyncReady: () async {
          ensured = true;
          // ensureLoaded start'tan ÖNCE çağrılmalı (cache-ready garantisi).
          expect(remote.pullCount, 0, reason: 'ensure start öncesi');
        },
      );
      c.liveSyncResolver = () async => true;
      addTearDown(() {
        if (ensureCalledFirst) expect(ensured, isTrue, reason: 'ensureLoaded çağrıldı');
      });
      return c;
    }

    test('flag false → start ÇAĞRILMAZ (pull/subscribe yok — review [P2]#2)', () async {
      cubit = buildWithFlag(flagEnabled: false);
      await cubit.load();
      await Future<void>.delayed(Duration.zero);
      expect(remote.pullCount, 0, reason: 'kill-switch: catch-up pull yok');
      expect(remote.subscribeCount, 0);
      expect(cubit.syncEnabled, isFalse, reason: 'toggle gizli');
    });

    test('flag true → start çalışır (Patch 3 davranışı)', () async {
      cubit = buildWithFlag(flagEnabled: true);
      await cubit.load();
      await Future<void>.delayed(Duration.zero);
      expect(remote.pullCount, greaterThanOrEqualTo(1));
      expect(cubit.syncEnabled, isTrue);
    });

    test('flag false → syncNow/enableLiveSync no-op', () async {
      cubit = buildWithFlag(flagEnabled: false, ensureCalledFirst: false);
      await cubit.load();
      await Future<void>.delayed(Duration.zero);
      final pulls = remote.pullCount;
      await cubit.syncNow();
      cubit.enableLiveSync();
      expect(remote.pullCount, pulls);
      expect(remote.subscribeCount, 0);
    });
  });

  // ── Denetim A4 — servis-içi kilit VaultCubit._opChain ile KİLİTLENMEZ ────────
  group('A4 — kilit etkileşimi (deadlock yok)', () {
    test('uçuştaki push kullanıcı mutasyonunu BLOKLAMAZ, merge push bitince '
        'uygulanır', () async {
      cubit = buildWithSync();
      await cubit.load();
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      rawStore.dirty = [
        RawTokenRecord(
            id: 'd', blob: _blob(), updatedAtMs: 1, serverUpdatedAtIso: null),
      ];
      final gate = Completer<void>();
      remote.pushGate = gate;
      final importsBefore = rawStore.importCount;

      // syncNow: push kilidi alır ve gate'te bekler; merge kilidi bekler ve
      // (kilidi aldığında) VaultCubit._opChain'e girer.
      final sync = cubit.syncNow();
      await Future<void>.delayed(Duration.zero);

      // Kullanıcı bu sırada token ekliyor: mutasyon _opChain'de, push'u
      // AWAIT ETMEZ → kilit beklerken bile tamamlanmalı (deadlock yok).
      await cubit.add(_acc('kullanici')).timeout(const Duration(seconds: 2));
      expect(cubit.state.accounts.map((a) => a.accountName), ['kullanici']);
      expect(rawStore.importCount, importsBefore,
          reason: 'merge push bitmeden diske yazmaz');

      gate.complete();
      await sync.timeout(const Duration(seconds: 2));

      expect(rawStore.importCount, importsBefore + 1,
          reason: 'merge push bitince _opChain üzerinden uygulandı');
    });
  });
}
