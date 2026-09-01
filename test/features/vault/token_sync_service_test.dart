/// TokenSyncService testleri (Faz 3 Patch 3) — push→pull→merge→cursor sırası,
/// subscribe-önce/pull-sonra, error→status, live toggle, dispose sonrası no-op.
///
/// FakeRemoteTokenRepository (emitChange ile Realtime simülasyonu) + fake RawTokenStore.
/// Gerçek ağ GEREKMEZ.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/features/account/domain/sync_exceptions.dart';
import 'package:project_auth/features/vault/data/last_sync_store.dart';
import 'package:project_auth/features/vault/domain/raw_token_record.dart';
import 'package:project_auth/features/vault/domain/remote_token_repository.dart';
import 'package:project_auth/features/vault/domain/token_sync_service.dart';

class FakeSecureStorage implements FlutterSecureStorage {
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
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

EncryptedBlob _b() =>
    EncryptedBlob(nonce: Uint8List(24), ciphertext: Uint8List(16));

RemoteTokenRow _row(String id, String iso) => RemoteTokenRow(
    id: id, blob: _b(), version: 1, serverUpdatedAt: DateTime.parse(iso), deleted: false);

class FakeRemote implements RemoteTokenRepository {
  RemotePullResult next = const RemotePullResult(rows: []);
  SyncError? pullError;
  int pushCount = 0;
  List<RawTokenRecord> lastPushed = const [];
  int pullCount = 0;
  String? lastSinceIso;
  void Function()? _onChange;
  int subscribeCount = 0;
  int unsubscribeCount = 0;

  void emitChange() => _onChange?.call();

  @override
  Future<RemotePullResult> pullSince(String uid, String? sinceIso) async {
    pullCount++;
    lastSinceIso = sinceIso;
    if (pullError != null) throw pullError!;
    return next;
  }

  SyncError? pushError;

  @override
  Future<void> pushUpsert(String uid, List<RawTokenRecord> records) async {
    pushCount++;
    lastPushed = records;
    if (pushError != null) throw pushError!;
  }

  @override
  RealtimeChannelHandle subscribe(String uid, void Function() onChange) {
    subscribeCount++;
    _onChange = onChange;
    return _FakeHandle(this);
  }

  @override
  Future<void> tombstoneAllRemote(String uid) async {}
  @override
  Future<void> tombstoneAllRemoteBefore(String uid, String beforeIso) async {}
}

class _FakeHandle implements RealtimeChannelHandle {
  _FakeHandle(this.remote);
  final FakeRemote remote;
  @override
  Future<void> unsubscribe() async {
    remote.unsubscribeCount++;
    remote._onChange = null;
  }
}

class FakeRawStore implements RawTokenStore {
  List<RawTokenRecord> raw = [];
  int importCount = 0;
  String? lastPullCursor;
  TokenMergeOutcome importResult = const TokenMergeOutcome(changed: true, appliedCount: 1);

  @override
  Future<List<RawTokenRecord>> exportRaw() async => raw;

  @override
  Future<TokenMergeOutcome> importRemote(List<RemoteTokenRow> remote,
      {required String? pullCursorIso}) async {
    importCount++;
    lastPullCursor = pullCursorIso;
    return importResult;
  }

  @override
  Future<void> markDeleted(String id) async {}
}

void main() {
  late FakeRemote remote;
  late FakeRawStore store;
  late LastSyncStore lastSync;
  late List<SyncState> statuses;
  late int mergedCount;

  TokenSyncService build({String uid = 'u1', bool mergeReturnsNull = false}) {
    statuses = [];
    mergedCount = 0;
    return TokenSyncService(
      remote: remote,
      store: store,
      lastSync: lastSync,
      uid: uid,
      // VaultCubit.applyRemoteMerge'i taklit eder: importRemote + (changed) merge sayacı.
      // mergeReturnsNull=true → vault kapanmış gibi null (merge YAPILAMADI).
      mergeRemote: (rows, cursor) async {
        if (mergeReturnsNull) return null;
        final outcome = await store.importRemote(rows, pullCursorIso: cursor);
        if (outcome.changed) mergedCount++;
        return outcome;
      },
      onStatus: statuses.add,
    );
  }

  setUp(() {
    remote = FakeRemote();
    store = FakeRawStore();
    lastSync = LastSyncStore(storage: FakeSecureStorage());
  });

  test('syncOnce: cursor oku → push → pull(cursor0) → merge(pullCursor:cursor0) → cursor ilerlet', () async {
    await lastSync.write('2026-06-09T09:00:00.000Z');
    store.raw = [
      RawTokenRecord(id: 'd', blob: _b(), updatedAtMs: 1, serverUpdatedAtIso: null), // dirty
    ];
    remote.next = RemotePullResult(
      rows: [_row('x', '2026-06-09T10:00:00Z')],
      safeCursorIso: '2026-06-09T10:00:00.000Z',
    );
    final svc = build();
    await svc.syncOnce();

    expect(remote.pushCount, 1, reason: 'dirty push edildi');
    expect(remote.lastPushed.single.id, 'd');
    expect(remote.lastSinceIso, '2026-06-09T09:00:00.000Z', reason: 'pull cursor0 ile');
    expect(store.lastPullCursor, '2026-06-09T09:00:00.000Z', reason: 'merge pullCursorIso=cursor0');
    expect(await lastSync.read(), '2026-06-09T10:00:00.000Z', reason: 'cursor safeCursorIso\'ya ilerledi');
    expect(mergedCount, 1, reason: 'changed → onMergedChanged');
    expect(statuses.last.phase, SyncPhase.idle);
  });

  test('safeCursorIso null → cursor İLERLEMEZ', () async {
    await lastSync.write('2026-06-09T09:00:00.000Z');
    remote.next = const RemotePullResult(rows: [], safeCursorIso: null);
    store.importResult = TokenMergeOutcome.none;
    final svc = build();
    await svc.syncOnce();
    expect(await lastSync.read(), '2026-06-09T09:00:00.000Z', reason: 'cursor sabit kaldı');
  });

  test('merge null (vault kapandı) → cursor İLERLEMEZ (reviewer [P1] veri kaybı önlenir)',
      () async {
    await lastSync.write('2026-06-09T09:00:00.000Z');
    remote.next = RemotePullResult(
        rows: [_row('x', '2026-06-09T10:00:00Z')], // satır VAR + safeCursor VAR
        safeCursorIso: '2026-06-09T10:00:00.000Z');
    final svc = build(mergeReturnsNull: true); // merge UYGULANAMADI
    await svc.syncOnce();
    expect(await lastSync.read(), '2026-06-09T09:00:00.000Z',
        reason: 'merge yapılmadıysa cursor ilerlemez → satırlar sonraki pull\'da tekrar gelir');
  });

  test('malformedCount status\'a yansır', () async {
    remote.next = RemotePullResult(
        rows: [_row('x', '2026-06-09T10:00:00Z')],
        malformedCount: 2,
        safeCursorIso: '2026-06-09T10:00:00.000Z');
    final svc = build();
    await svc.syncOnce();
    expect(statuses.last.phase, SyncPhase.idle);
    expect(statuses.last.malformedCount, 2);
  });

  test('push hatası pull\'u ENGELLEMEZ (reviewer [P2]) → pull+merge yine çalışır', () async {
    store.raw = [
      RawTokenRecord(id: 'd', blob: _b(), updatedAtMs: 1, serverUpdatedAtIso: null), // dirty
    ];
    remote.pushError = const SyncNetworkError(); // push başarısız
    remote.next = RemotePullResult(
        rows: [_row('x', '2026-06-09T10:00:00Z')],
        safeCursorIso: '2026-06-09T10:00:00.000Z');
    final svc = build();
    await svc.syncOnce();
    expect(remote.pushCount, 1, reason: 'push denendi');
    expect(remote.pullCount, 1, reason: 'push fail OLSA BİLE pull çalıştı');
    expect(mergedCount, 1, reason: 'merge uygulandı');
    expect(statuses.last.phase, SyncPhase.idle, reason: 'push fail tek başına error YAPMAZ');
  });

  test('pull hatası → SyncPhase.error (re-throw yok)', () async {
    remote.pullError = const SyncNetworkError();
    final svc = build();
    await svc.syncOnce(); // throw ETMEMELİ
    expect(statuses.last.phase, SyncPhase.error);
    expect(statuses.last.error, isA<SyncNetworkError>());
  });

  test('start(live:true): subscribe ÖNCE, pull SONRA', () async {
    remote.next = const RemotePullResult(rows: []);
    store.importResult = TokenMergeOutcome.none;
    final svc = build();
    await svc.start(live: true);
    expect(remote.subscribeCount, 1);
    expect(remote.pullCount, 1);
  });

  test('start(live:false): abone YOK, yalnız syncOnce', () async {
    remote.next = const RemotePullResult(rows: []);
    store.importResult = TokenMergeOutcome.none;
    final svc = build();
    await svc.start(live: false);
    expect(remote.subscribeCount, 0);
    expect(remote.pullCount, 1);
  });

  test('Realtime olayı (idle) → syncOnce tetikler', () async {
    remote.next = const RemotePullResult(rows: []);
    store.importResult = TokenMergeOutcome.none;
    final svc = build();
    await svc.start(live: true);
    final before = remote.pullCount;
    remote.emitChange();
    await Future<void>.delayed(Duration.zero);
    expect(remote.pullCount, before + 1);
  });

  test('enableLive/disableLive: oturum-içi abone aç/kapa', () async {
    final svc = build();
    svc.enableLive();
    expect(remote.subscribeCount, 1);
    await svc.disableLive();
    expect(remote.unsubscribeCount, 1);
  });

  test('dispose sonrası syncOnce + onChange no-op, abonelik kapanır', () async {
    final svc = build();
    svc.enableLive();
    await svc.dispose();
    expect(remote.unsubscribeCount, 1);
    final pullsBefore = remote.pullCount;
    await svc.syncOnce(); // no-op
    expect(remote.pullCount, pullsBefore);
    remote.emitChange(); // handle null → no-op
    await Future<void>.delayed(Duration.zero);
    expect(remote.pullCount, pullsBefore);
  });

  test('pushChanged: yalnız dirty kayıtları gönderir', () async {
    store.raw = [
      RawTokenRecord(id: 'clean', blob: _b(), updatedAtMs: 1, serverUpdatedAtIso: '2026-06-09T08:00:00.000Z'),
      RawTokenRecord(id: 'dirty', blob: _b(), updatedAtMs: 1, serverUpdatedAtIso: null),
    ];
    final svc = build();
    await svc.pushChanged();
    expect(remote.pushCount, 1);
    expect(remote.lastPushed.map((r) => r.id), ['dirty']);
  });

  test('pushChanged: dirty yoksa no-op', () async {
    store.raw = [
      RawTokenRecord(id: 'clean', blob: _b(), updatedAtMs: 1, serverUpdatedAtIso: '2026-06-09T08:00:00.000Z'),
    ];
    final svc = build();
    await svc.pushChanged();
    expect(remote.pushCount, 0);
  });

  // ── Faz 3 Patch 4 (Adım F) — token_sync_enabled kill-switch ──────────────────
  group('kill-switch (token_sync_enabled)', () {
    late ValueNotifier<int> flagVersion;
    late bool flagEnabled;
    late bool livePref;

    TokenSyncService buildGated() {
      statuses = [];
      mergedCount = 0;
      return TokenSyncService(
        remote: remote,
        store: store,
        lastSync: lastSync,
        uid: 'u1',
        mergeRemote: (rows, cursor) async {
          final outcome = await store.importRemote(rows, pullCursorIso: cursor);
          if (outcome.changed) mergedCount++;
          return outcome;
        },
        onStatus: statuses.add,
        isEnabled: () => flagEnabled,
        flagListenable: flagVersion,
        livePreferenceResolver: () async => livePref,
      );
    }

    setUp(() {
      flagVersion = ValueNotifier<int>(0);
      flagEnabled = true;
      livePref = false;
    });

    test('flag false → syncOnce no-op (pull yok)', () async {
      flagEnabled = false;
      remote.next = RemotePullResult(
          rows: [_row('x', '2026-06-09T10:00:00Z')],
          safeCursorIso: '2026-06-09T10:00:00.000Z');
      final svc = buildGated();
      await svc.syncOnce();
      expect(remote.pullCount, 0, reason: 'kill-switch: pull çalışmaz');
    });

    test('flag false → start no-op (subscribe + pull YOK)', () async {
      flagEnabled = false;
      final svc = buildGated();
      await svc.start(live: true);
      expect(remote.subscribeCount, 0);
      expect(remote.pullCount, 0);
    });

    test('flag false → Realtime event no-op (BYPASS YOK — review [P1]#1)', () async {
      // Önce flag açık → abone ol, sonra flag'i kapat → event gelirse sync OLMAMALI.
      flagEnabled = true;
      remote.next = const RemotePullResult(rows: []);
      store.importResult = TokenMergeOutcome.none;
      final svc = buildGated();
      await svc.start(live: true);
      final pullsAfterStart = remote.pullCount;
      flagEnabled = false; // kill-switch devreye girdi
      remote.emitChange(); // Realtime tetikleyici
      await Future<void>.delayed(Duration.zero);
      expect(remote.pullCount, pullsAfterStart,
          reason: 'flag false → _onRealtimeEvent syncOnce çağırmaz');
    });

    test('flag false → pushChanged + enableLive no-op', () async {
      flagEnabled = false;
      store.raw = [
        RawTokenRecord(id: 'd', blob: _b(), updatedAtMs: 1, serverUpdatedAtIso: null),
      ];
      final svc = buildGated();
      await svc.pushChanged();
      svc.enableLive();
      expect(remote.pushCount, 0);
      expect(remote.subscribeCount, 0);
    });

    test('flag false→true notify + livePref AÇIK → enableLive (review R3[P2]#1)', () async {
      flagEnabled = false;
      livePref = true;
      final svc = buildGated();
      // Başlangıçta flag kapalı → abone yok.
      svc.enableLive();
      expect(remote.subscribeCount, 0);
      // Flag açıldı + notify → listener livePref açık olduğu için enableLive.
      flagEnabled = true;
      flagVersion.value++;
      await Future<void>.delayed(Duration.zero);
      expect(remote.subscribeCount, 1, reason: 'flag→true + livePref → abone geri açılır');
    });

    test('flag false→true notify ama livePref KAPALI → enableLive ÇAĞRILMAZ', () async {
      flagEnabled = false;
      livePref = false;
      buildGated(); // listener ctor'da bağlanır; servis referansı gerekmez
      flagEnabled = true;
      flagVersion.value++;
      await Future<void>.delayed(Duration.zero);
      expect(remote.subscribeCount, 0);
    });

    test('flag true→false notify → disableLive (orphan abonelik temizliği)', () async {
      flagEnabled = true;
      remote.next = const RemotePullResult(rows: []);
      store.importResult = TokenMergeOutcome.none;
      final svc = buildGated();
      await svc.start(live: true);
      expect(remote.subscribeCount, 1);
      flagEnabled = false;
      flagVersion.value++;
      await Future<void>.delayed(Duration.zero);
      expect(remote.unsubscribeCount, 1, reason: 'flag→false → disableLive');
    });

    test('dispose → flag listener kaldırılır (notify sonrası no-op)', () async {
      flagEnabled = true;
      livePref = true;
      final svc = buildGated();
      await svc.dispose();
      flagVersion.value++; // dispose sonrası notify
      await Future<void>.delayed(Duration.zero);
      expect(remote.subscribeCount, 0, reason: 'dispose sonrası listener etkisiz');
    });

    test('flag açık → davranış Patch 3 ile birebir (regresyon yok)', () async {
      flagEnabled = true;
      remote.next = RemotePullResult(
          rows: [_row('x', '2026-06-09T10:00:00Z')],
          safeCursorIso: '2026-06-09T10:00:00.000Z');
      final svc = buildGated();
      await svc.syncOnce();
      expect(remote.pullCount, 1);
      expect(mergedCount, 1);
    });
  });
}
