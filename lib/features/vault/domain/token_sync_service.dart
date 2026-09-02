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
typedef MergeRemote =
    Future<TokenMergeOutcome?> Function(
      List<RemoteTokenRow> rows,
      String? pullCursorIso,
    );

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

  SyncState copyWith({
    SyncPhase? phase,
    int? malformedCount,
    SyncError? error,
  }) => SyncState(
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
  }) : _remote = remote,
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
    // A5: flag'in BAŞLANGIÇ değeri burada sabitlenir (lazy `late` DEĞİL — ilk
    // erişim `_onFlagChanged` içinde olurdu ve false→true geçişi kaçardı).
    _lastEnabled = _enabled;
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

  /// Kill-switch'in en son GÖRÜLEN değeri — `_onFlagChanged` false→true geçişini
  /// buradan anlar (her flag notify'ında değil, YALNIZ yeniden açılışta resync).
  late bool _lastEnabled;

  /// **Store-vs-network mutex (audit A4).** Serializes the two critical regions
  /// that both read the vault blob and write somewhere else:
  ///
  ///   - `_pushDirty`: `exportRaw` (read disk) → `pushUpsert` (write server)
  ///   - `_mergeRemote`: apply server rows (write disk)
  ///
  /// Without it a long import push and an incoming merge interleave: the merge
  /// writes a NEWER blob to disk while the in-flight push is still uploading the
  /// snapshot it read before the merge, so the server ends up with the STALE
  /// blob and the next pull hands it back. Under the lock a merge either waits
  /// for the push to finish, or the push runs after the merge and re-reads the
  /// dirty set from the already-merged disk.
  ///
  /// NOT VaultCubit's `_opChain`: that sequencer guards UI mutations, and the
  /// merge callback already runs inside it — reusing it here would put a
  /// network round trip inside the queue every user mutation waits on.
  ///
  /// DEADLOCK-FREE by construction: the regions are never nested (`syncOnce`
  /// takes the lock twice in sequence, not recursively), and the one path that
  /// crosses into `_opChain` — the merge region — is only ever entered from a
  /// mutation that fires `pushChanged()` WITHOUT awaiting it, so `_opChain`
  /// never waits on this lock.
  Future<void> _storeLock = Future<void>.value();

  /// Runs [action] with [_storeLock] held. The lock is released even when
  /// [action] throws (push failures are best-effort and must not wedge sync).
  Future<T> _locked<T>(Future<T> Function() action) {
    final release = Completer<void>();
    final previous = _storeLock;
    _storeLock = release.future;
    return previous
        .then((_) => action())
        .whenComplete(() => release.complete());
  }

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
    if (_disposed || _syncing || !_enabled) {
      return; // kill-switch (Realtime bypass dahil)
    }
    _syncing = true;
    _emit(const SyncState(phase: SyncPhase.syncing));
    try {
      final cursor0 = await _lastSync.read();

      // 1) Push (dirty kayıtlar) — GERÇEKTEN best-effort: hatası pull'u ENGELLEMEZ
      //    (reviewer [P2]). Push başarısız olsa bile remote değişiklikleri çekilmeli.
      try {
        await _locked(_pushDirty); // A4: exportRaw+pushUpsert atomik bölge
      } catch (_) {
        // best-effort; bir sonraki tur reconcile eder (push edilemeyen dirty kalır).
      }

      // 2) Pull (cursor0'dan sonrası).
      final result = await _remote.pullSince(_uid, cursor0);
      _lastMalformed = result.malformedCount;

      // 3) Merge — VaultCubit sequencer'ı ALTINDA (import yazımı + reload tek kritik
      //    bölümde; kullanıcı add/delete ile yarışmaz — reviewer [P1]). pullCursorIso=cursor0
      //    (dirty-vs-echo ayrımı için ŞART). _store.importRemote DOĞRUDAN çağrılMAZ.
      // A4: merge de AYNI kilit altında — uçuştaki bir push bitmeden disk
      // değişmez, bir sonraki push merge SONRASI diski okur.
      final merged = await _locked(() => _mergeRemote(result.rows, cursor0));

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
        _emit(
          SyncState(
            phase: SyncPhase.error,
            malformedCount: _lastMalformed,
            error: e,
          ),
        );
      }
    } catch (_) {
      // SyncError dışı (IO/parse) → yine error state; kullanıcı bloklanmaz.
      if (!_disposed) {
        _emit(
          SyncState(phase: SyncPhase.error, malformedCount: _lastMalformed),
        );
      }
    } finally {
      _syncing = false;
    }
  }

  /// save sonrası (add/edit/increment): dirty kayıtları best-effort push. Boşsa no-op.
  Future<void> pushChanged() async {
    if (_disposed || !_enabled) return; // kill-switch
    try {
      // A4: kilit altında — süren bir merge biter, sonra dirty TAZE okunur.
      await _locked(_pushDirty);
    } catch (_) {
      // best-effort; bir sonraki syncOnce reconcile eder.
    }
  }

  /// Dirty (sv == null) kayıtları tek batch hâlinde push eder.
  ///
  /// **Id başına tek satır (A2 — defence in depth):** `pushUpsert` `onConflict:
  /// 'id'` kullanır; aynı batch bir id'yi iki kez taşırsa Postgres 21000 ("ON
  /// CONFLICT DO UPDATE command cannot affect row a second time") döner ve
  /// SONRAKİ TÜM push'lar kilitlenir. `EncryptedVaultRepository.exportRaw` zaten
  /// tekilleştiriyor, ama `RawTokenStore` bir PORT (başka bir implementasyon veya
  /// elle düzenlenmiş/yarım merge edilmiş bir dosya mükerrer id verebilir) → burada
  /// da daralt. Kural store ile aynı: CANLI kayıt kendi tombstone'unu yener
  /// (kasıtlı diriltme), aynı türden ikisinde İLKİ kazanır — "son kazanır" bir
  /// diriltmeyi tombstone'a çevirebilirdi (sessiz token kaybı).
  Future<void> _pushDirty() async {
    final raw = await _store.exportRaw();
    final byId = <String, RawTokenRecord>{};
    for (final r in raw) {
      if (!r.isDirty) continue;
      final seen = byId[r.id];
      if (seen == null || (seen.deleted && !r.deleted)) byId[r.id] = r;
    }
    if (byId.isEmpty) return;
    await _remote.pushUpsert(_uid, byId.values.toList(growable: false));
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
    if (_disposed || !_enabled) {
      return; // kill-switch: Realtime tetikleyici no-op (bypass YOK)
    }
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
    final enabled = _enabled;
    final reEnabled = enabled && !_lastEnabled;
    _lastEnabled = enabled;
    if (!enabled) {
      unawaited(disableLive());
      return;
    }
    unawaited(_onFlagEnabled(reEnabled));
  }

  /// Flag AÇIK durumdayken yapılacaklar: aboneliği tercihe göre geri kur, ve
  /// kill-switch YENİ açıldıysa (false→true) bir catch-up `syncOnce` çalıştır.
  ///
  /// **A5 — resync ŞART:** flag kapalıyken `syncOnce`/`pushChanged` ve Realtime
  /// tetikleyicisinin HEPSİ no-op'tu; o pencerede sunucuda biriken satırlar ve
  /// lokal dirty kayıtlar bir sonraki tetiği (unlock / kullanıcı mutasyonu)
  /// bekliyordu. Aboneliği geri açmak yetmez: Realtime yalnız BUNDAN SONRAKİ
  /// değişikliği haber verir. Sıra `start` ile aynı: önce abone, sonra pull.
  Future<void> _onFlagEnabled(bool reEnabled) async {
    try {
      final live =
          await (_livePreferenceResolver?.call() ?? Future<bool>.value(false));
      if (_disposed || !_enabled) return;
      if (live) enableLive();
    } catch (_) {
      // canlı tercih okunamadı → abonelik olduğu gibi kalır; resync yine yapılır.
    }
    if (reEnabled && !_disposed && _enabled) await syncOnce();
  }

  /// VaultCubit.close → çağrılır. Aboneliği kapatır; sonrası tüm callback'ler no-op.
  Future<void> dispose() async {
    _disposed = true;
    _flagListenable?.removeListener(
      _onFlagChanged,
    ); // self-subscribe temizliği (Adım F)
    final ch = _channel;
    _channel = null;
    await ch?.unsubscribe();
  }
}
