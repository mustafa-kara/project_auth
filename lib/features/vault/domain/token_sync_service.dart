/// Token sync orchestrator (Faz 3 Patch 3) — push/pull/merge + Realtime + cursor.
///
/// **masterKey TUTMAZ** (opak `RawTokenStore` + `RemoteTokenRepository` ile çalışır).
/// VaultCubit subtree'sine bağlı yaşar: unlock'ta `start`, lock/arka-plan/signOut'ta
/// `dispose` (VaultCubit.close). Best-effort: hata kullanıcıyı BLOKLAMAZ (sync zorunlu
/// değil; vault lokalde çalışır), bir sonraki tetikte yeniden denenir.
///
/// **Sıra (subscribe-önce / pull-sonra):** canlı modda ÖNCE abone ol (olayları coalesce
/// flag'ine tampona al), SONRA catch-up `syncOnce`; pull biterken flag set ise BİR kez
/// daha `syncOnce` (kaçan-olay penceresi kapanır). Merge idempotent → çift zararsız.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../account/domain/sync_exceptions.dart';
import '../data/last_sync_store.dart';
import 'raw_token_record.dart';
import 'remote_token_repository.dart';

enum SyncPhase { idle, syncing, error }

/// Remote satırları diske merge edip (değişikse) UI'ı reload eden callback tipi.
/// VaultCubit sequencer'ı altında çalışır (import yazımı mutasyonlarla serileşir).
/// **`null` döner = merge UYGULANAMADI** (vault kapandı/ilk-load yok) → cursor ilerletilmez.
typedef MergeRemote = Future<TokenMergeOutcome?> Function(
    List<RemoteTokenRow> rows, String? pullCursorIso);

/// Sync durumu — göstergeyi besler. Enum yetersiz: malformedCount + son hata taşır.
class SyncState {
  final SyncPhase phase;

  /// Son pull'da karantina edilen (bozuk) sunucu satırı sayısı.
  final int malformedCount;

  /// Son sync hatası (varsa). `phase == error` iken anlamlı.
  final SyncError? error;

  const SyncState({
    this.phase = SyncPhase.idle,
    this.malformedCount = 0,
    this.error,
  });

  static const idle = SyncState();

  SyncState copyWith({SyncPhase? phase, int? malformedCount, SyncError? error}) =>
      SyncState(
        phase: phase ?? this.phase,
        malformedCount: malformedCount ?? this.malformedCount,
        error: error,
      );

  @override
  bool operator ==(Object other) =>
      other is SyncState &&
      other.phase == phase &&
      other.malformedCount == malformedCount &&
      other.error.runtimeType == error.runtimeType;

  @override
  int get hashCode => Object.hash(phase, malformedCount, error.runtimeType);
}

class TokenSyncService {
  TokenSyncService({
    required RemoteTokenRepository remote,
    required RawTokenStore store,
    required LastSyncStore lastSync,
    required String uid,
    required MergeRemote mergeRemote,
    required void Function(SyncState) onStatus,
    bool Function()? isEnabled,
    ValueListenable<int>? flagListenable,
    Future<bool> Function()? livePreferenceResolver,
  })  : _remote = remote,
        _store = store,
        _lastSync = lastSync,
        _uid = uid,
        _mergeRemote = mergeRemote,
        _onStatus = onStatus,
        _isEnabled = isEnabled,
        _flagListenable = flagListenable,
        _livePreferenceResolver = livePreferenceResolver {
    // Faz 3 Patch 4 (Adım F): flag değişince gate'i yeniden değerlendir (SELF-SUBSCRIBE —
    // root'ta cubit ref'i GEREKMEZ; Realtime bypass'ı kapatır). VaultCubit gate'i YETMEZ
    // çünkü _onRealtimeEvent doğrudan syncOnce çağırır.
    _flagListenable?.addListener(_onFlagChanged);
  }

  final RemoteTokenRepository _remote;
  final RawTokenStore _store;
  final LastSyncStore _lastSync;
  final String _uid;

  /// token_sync_enabled kill-switch (Adım F). null → her zaman true (legacy/test).
  final bool Function()? _isEnabled;
  final ValueListenable<int>? _flagListenable;
  final Future<bool> Function()? _livePreferenceResolver;

  /// Gate: kill-switch açık mı (null isEnabled → daima açık).
  bool get _enabled => _isEnabled?.call() ?? true;

  /// Remote satırları diske MERGE eden + (değişikse) VaultCubit state'ini reload eden
  /// callback. **VaultCubit'in mutasyon sequencer'ı ALTINDA çalışır** (reviewer [P1]:
  /// import disk yazımı kullanıcı add/delete ile yarışmasın). `importRemote`'u service
  /// DOĞRUDAN çağırMAZ — bu callback üzerinden geçer (tek yazma kuyruğu).
  final MergeRemote _mergeRemote;
  final void Function(SyncState) _onStatus;

  RealtimeChannelHandle? _channel;
  bool _disposed = false;
  bool _syncing = false; // tek seferde tek syncOnce (reentrancy guard)
  bool _pendingEvent = false; // sync sürerken gelen Realtime olayı işareti
  int _lastMalformed = 0;

  /// Unlock'ta çağrılır. [live] → Realtime aboneliği aç (subscribe ÖNCE, pull SONRA).
  Future<void> start({required bool live}) async {
    if (_disposed || !_enabled) return; // kill-switch: token sync HİÇ başlamaz
    if (live) {
      _subscribe(); // ÖNCE abone (gelen olaylar _pendingEvent'e tamponlanır)
    }
    await syncOnce(); // catch-up pull+merge
    // pull sırasında olay geldiyse bir kez daha (kaçan-olay penceresi).
    if (!_disposed && _pendingEvent) {
      _pendingEvent = false;
      await syncOnce();
    }
  }

  /// Tam bir sync turu: cursor oku → push (dirty) → pull → merge → cursor ilerlet.
  /// Best-effort: hata → `SyncPhase.error` (re-throw YOK).
  Future<void> syncOnce() async {
    if (_disposed || _syncing || !_enabled) return; // kill-switch (Realtime bypass dahil)
    _syncing = true;
    _emit(const SyncState(phase: SyncPhase.syncing));
    try {
      final cursor0 = await _lastSync.read();

      // 1) Push (dirty kayıtlar) — GERÇEKTEN best-effort: hatası pull'u ENGELLEMEZ
      //    (reviewer [P2]). Push başarısız olsa bile remote değişiklikleri çekilmeli.
      try {
        await _pushDirty();
      } catch (_) {
        // best-effort; bir sonraki tur reconcile eder (push edilemeyen dirty kalır).
      }

      // 2) Pull (cursor0'dan sonrası).
      final result = await _remote.pullSince(_uid, cursor0);
      _lastMalformed = result.malformedCount;

      // 3) Merge — VaultCubit sequencer'ı ALTINDA (import yazımı + reload tek kritik
      //    bölümde; kullanıcı add/delete ile yarışmaz — reviewer [P1]). pullCursorIso=cursor0
      //    (dirty-vs-echo ayrımı için ŞART). _store.importRemote DOĞRUDAN çağrılMAZ.
      final merged = await _mergeRemote(result.rows, cursor0);

      // 4) Cursor ilerlet — YALNIZ (a) merge GERÇEKTEN UYGULANDIYSA (merged != null;
      //    vault kapandıysa null → remote satırlar diske YAZILMADI → cursor ilerlerse
      //    sonraki pull onları atlar — reviewer [P1]) + (b) teardown olmadıysa + (c)
      //    safeCursorIso cap'i (null ise ilerletme: bozuk-satır gap'i veya boş pull).
      if (merged != null && !_disposed && result.safeCursorIso != null) {
        await _lastSync.write(result.safeCursorIso!);
      }

      if (_disposed) return;
      _emit(SyncState(phase: SyncPhase.idle, malformedCount: _lastMalformed));
    } on SyncError catch (e) {
      if (!_disposed) {
        _emit(SyncState(phase: SyncPhase.error, malformedCount: _lastMalformed, error: e));
      }
    } catch (_) {
      // SyncError dışı (IO/parse) → yine error state; kullanıcı bloklanmaz.
      if (!_disposed) {
        _emit(SyncState(phase: SyncPhase.error, malformedCount: _lastMalformed));
      }
    } finally {
      _syncing = false;
    }
  }

  /// save sonrası (add/edit/increment): dirty kayıtları best-effort push. Boşsa no-op.
  Future<void> pushChanged() async {
    if (_disposed || !_enabled) return; // kill-switch
    try {
      await _pushDirty();
    } catch (_) {
      // best-effort; bir sonraki syncOnce reconcile eder.
    }
  }

  Future<void> _pushDirty() async {
    final raw = await _store.exportRaw();
    final dirty = raw.where((r) => r.isDirty).toList(growable: false);
    if (dirty.isEmpty) return;
    await _remote.pushUpsert(_uid, dirty);
  }

  /// Canlı senkronu oturum-içi aç (subtree tear-down YOK).
  void enableLive() {
    if (_disposed || _channel != null || !_enabled) return; // kill-switch
    _subscribe();
  }

  /// Canlı senkronu oturum-içi kapat (catch-up sync save/unlock'ta yine çalışır).
  Future<void> disableLive() async {
    final ch = _channel;
    _channel = null;
    await ch?.unsubscribe();
  }

  void _subscribe() {
    _channel = _remote.subscribe(_uid, _onRealtimeEvent);
  }

  /// Realtime olayı = yalnız TETİKLEYİCİ (payload OKUNMAZ — #1180). sync sürüyorsa
  /// işaretle (coalesce), değilse REST pull tetikle.
  void _onRealtimeEvent() {
    if (_disposed || !_enabled) return; // kill-switch: Realtime tetikleyici no-op (bypass YOK)
    if (_syncing) {
      _pendingEvent = true;
      return;
    }
    unawaited(syncOnce());
  }

  void _emit(SyncState s) {
    if (_disposed) return;
    _onStatus(s);
  }

  /// Flag değişti (FeatureFlagsService.refresh notify) — gate'i yeniden değerlendir.
  /// **İKİ YÖN (review R3[P2]#1 — effective-state tutarlılığı):** flag→false → `disableLive`
  /// (orphan abonelik temizliği); flag→true + kullanıcı `live` tercihi açık → `enableLive`
  /// (toggle "açık" ⇔ abonelik aktif). `enableLive` idempotent (_channel!=null → no-op).
  void _onFlagChanged() {
    if (_disposed) return;
    if (!_enabled) {
      unawaited(disableLive());
      return;
    }
    // Flag açıldı: kullanıcı tercihi açıksa aboneliği geri kur.
    final resolver = _livePreferenceResolver;
    if (resolver == null) return;
    unawaited(resolver().then((live) {
      if (!_disposed && _enabled && live) enableLive();
    }).catchError((_) {}));
  }

  /// VaultCubit.close → çağrılır. Aboneliği kapatır; sonrası tüm callback'ler no-op.
  Future<void> dispose() async {
    _disposed = true;
    _flagListenable?.removeListener(_onFlagChanged); // self-subscribe temizliği (Adım F)
    final ch = _channel;
    _channel = null;
    await ch?.unsubscribe();
  }
}
