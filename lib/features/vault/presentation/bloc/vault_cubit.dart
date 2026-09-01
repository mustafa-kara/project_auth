/// Vault durumu — kayıtlı OTP hesaplarının listesi.
///
/// Faz 1: token'lar `VaultRepository` (flutter_secure_storage) ile cihazda
/// kalıcı; her mutasyon sonrası kaydedilir. Faz 2: repository katmanı aynı
/// kalır, altına masterKey ile E2E şifreleme eklenir.
///
/// Faz 3 Patch 3: opsiyonel [TokenSyncService] ile bulut senkronu (push-on-save +
/// Realtime-tetikli reload-on-merge). `sync == null` (legacy/uid-siz) → davranış
/// BİREBİR korunur (sync inert). Token soft-delete (tombstone) sync'li yolda.
library;

import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/otp/otp_account.dart';
import '../../data/vault_load_result.dart';
import '../../data/vault_repository.dart';
import '../../domain/issuer_catalog.dart';
import '../../domain/raw_token_record.dart';
import '../../domain/remote_token_repository.dart';
import '../../domain/token_sync_service.dart';

class VaultState extends Equatable {
  /// İlk yükleme tamamlandı mı (depodan okuma). UI splash/boş-durum ayrımı için.
  final bool loaded;
  final List<OtpAccount> accounts;

  /// Çözülemeyen/atlanan bozuk kayıt sayısı (kısmi bozulma). >0 → UI banner.
  final int corruptedCount;

  /// Yükleme/bütünlük hatası (örn. tüm kayıtlar decrypt fail → integrity).
  /// Set ise UI "boş vault" yerine bütünlük hata ekranı gösterir.
  final Object? error;

  /// Faz 3 Patch 3 — bulut senkron durumu (gösterge). `sync == null` → idle kalır.
  final SyncState syncState;

  const VaultState({
    this.loaded = false,
    this.accounts = const [],
    this.corruptedCount = 0,
    this.error,
    this.syncState = SyncState.idle,
  });

  VaultState copyWith({
    bool? loaded,
    List<OtpAccount>? accounts,
    int? corruptedCount,
    Object? error,
    bool clearError = false,
    SyncState? syncState,
  }) =>
      VaultState(
        loaded: loaded ?? this.loaded,
        accounts: accounts ?? this.accounts,
        corruptedCount: corruptedCount ?? this.corruptedCount,
        error: clearError ? null : (error ?? this.error),
        syncState: syncState ?? this.syncState,
      );

  @override
  List<Object?> get props => [loaded, accounts, corruptedCount, error, syncState];
}

class VaultCubit extends Cubit<VaultState> {
  final VaultRepository _repository;

  /// Faz 3 Patch 3 — opsiyonel sync (null → legacy/uid-siz; davranış birebir).
  final TokenSyncService? _sync;

  /// Soft-delete + import için ham port (genelde `_repository` ile aynı instance).
  final RawTokenStore? _rawStore;

  /// Faz 3 Patch 4 (Adım F) — token_sync_enabled kill-switch. `start` öncesi bellek
  /// hazırlanır ([_ensureTokenSyncReady]) sonra okunur ([_tokenSyncEnabled]). null →
  /// her zaman açık (legacy/test; Patch 3 davranışı birebir). **YALNIZ token sync'i
  /// gate'ler — key_attributes (VaultLockCubit) flag-DIŞI.**
  final bool Function()? _tokenSyncEnabled;
  final Future<void> Function()? _ensureTokenSyncReady;

  /// Faz 3 Patch 4 (Adım E) — add-token sonrası issuer kanonikleştirme. Resolver
  /// güncel katalogu döner (refresh'te değişir); null → kanonikleştirme YOK (no-op,
  /// legacy/test davranışı korunur). Katalog boş/eşleşme yok → issuer DEĞİŞMEZ.
  final IssuerCatalog Function()? _issuerCatalogResolver;

  VaultCubit(
    this._repository, {
    TokenSyncService? sync,
    RawTokenStore? rawStore,
    bool Function()? tokenSyncEnabled,
    Future<void> Function()? ensureTokenSyncReady,
    IssuerCatalog Function()? issuerCatalogResolver,
  })  : _sync = sync,
        _rawStore = rawStore,
        _tokenSyncEnabled = tokenSyncEnabled,
        _ensureTokenSyncReady = ensureTokenSyncReady,
        _issuerCatalogResolver = issuerCatalogResolver,
        super(const VaultState());

  /// Issuer'ı katalog kanonik adına hizalar; eşleşme yok/katalog yok → DEĞİŞTİRMEZ.
  OtpAccount _canonicalize(OtpAccount account) {
    final catalog = _issuerCatalogResolver?.call();
    if (catalog == null) return account;
    final canon = catalog.canonicalIssuer(account.issuer);
    if (canon == null || canon == account.issuer) return account;
    return account.copyWith(issuer: canon);
  }

  /// Kill-switch açık mı (null → daima açık).
  bool get _syncFlagOn => _tokenSyncEnabled?.call() ?? true;

  /// İlk `load()` tamamlanma sinyali. Mutasyonlar (add/remove/increment) bunu
  /// bekler → henüz okunmamış depo kayıtlarını `save()` ile EZMEZ (review P1).
  final Completer<void> _firstLoad = Completer<void>();

  /// `load()` çağrıldı mı (idempotency + mutasyon-önce-load tetikleme için).
  bool _loadStarted = false;

  /// Mutasyon + merge-reload serileştirici (Faz 3 Patch 3 — reload-vs-mutation
  /// yarışını önler; her kritik bölüm bir öncekini bekler).
  Future<void> _opChain = Future<void>.value();

  /// İşlemleri sıraya alır (tek sequencer). Hata zinciri kırmaz (bir sonraki op çalışır).
  Future<void> _sequence(Future<void> Function() op) =>
      _sequenceValue<void>(op);

  /// Değer döndüren sequencer (importRemote outcome'ı için). Zincir hatada kırılmaz.
  Future<T> _sequenceValue<T>(Future<T> Function() op) {
    final next = _opChain.then((_) => op());
    _opChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<void> _awaitLoaded() {
    if (!_loadStarted) {
      unawaited(load());
    }
    return _firstLoad.future;
  }

  Future<void> load() async {
    if (_loadStarted) return _firstLoad.future; // tek ilk-yükleme (idempotent)
    _loadStarted = true;
    final VaultLoadResult result;
    try {
      result = await _repository.load();
    } catch (e) {
      // Bütünlük hatası (top-level bozulma / tüm kayıtlar decrypt fail) sessiz
      // "boş vault"a çevrilmez → hata state'i (UI integrity ekranı gösterir).
      emit(state.copyWith(loaded: true, error: e));
      if (!_firstLoad.isCompleted) _firstLoad.complete();
      return;
    }
    emit(state.copyWith(
      loaded: true,
      accounts: result.accounts,
      corruptedCount: result.corruptedCount,
      clearError: true,
    ));
    if (!_firstLoad.isCompleted) _firstLoad.complete();

    // Faz 3 Patch 3 — ilk load BİTTİKTEN sonra sync başlat (post-unlock; key_attributes
    // restore + unlock zaten gerçekleşti → kripto bağımlılık karşılandı). Best-effort.
    final sync = _sync;
    if (sync != null) {
      // Faz 3 Patch 4 (Adım F) — KILL-SWITCH cache-ready GARANTİSİ (review [P2]#2): start
      // öncesi flag bounded çözülür; sunucu AÇIKÇA false derse start HİÇ çağrılmaz (cache-boş
      // ilk açılışta fallback'in sync'i yanlışlıkla başlatmasını önler). timeout/offline →
      // fallback=true (sync çalışır). key_attributes bundan ETKİLENMEZ (VaultLockCubit ayrı).
      try {
        await (_ensureTokenSyncReady?.call() ?? Future<void>.value());
      } catch (_) {/* timeout/hata → fallback (isEnabled true) */}
      if (isClosed) return;
      if (!_syncFlagOn) return; // kill-switch: token sync başlamaz

      // Canlı tercihi BURADA çözülür (reviewer [P2] — race yok): resolver async olsa da
      // start ondan SONRA çağrılır. Resolver yoksa varsayılan kapalı. Hata → kapalı.
      bool live = false;
      try {
        live = await (_liveResolver?.call() ?? Future<bool>.value(false));
      } catch (_) {
        live = false;
      }
      if (isClosed) return;
      sync.start(live: live).ignore();
    }
  }

  /// `start(live:)` için canlı tercih çözücüsü (LiveSyncPrefStore.read) — main.dart enjekte eder.
  /// `load()` bunu start'tan ÖNCE await eder → persisted live=true unlock'ta uygulanır (race yok).
  Future<bool> Function()? _liveResolver;
  set liveSyncResolver(Future<bool> Function() r) => _liveResolver = r;

  /// Sync durumu değişince UI'a yansıt (TokenSyncService.onStatus → bunu çağırır).
  void updateSyncState(SyncState s) {
    if (isClosed) return;
    emit(state.copyWith(syncState: s));
  }

  /// TokenSyncService.mergeRemote → remote satırları diske MERGE eder + (değişikse) reload.
  /// **Sequencer ALTINDA** (reviewer [P1]: import disk yazımı kullanıcı add/delete/increment
  /// ile yarışmaz — hepsi tek `_opChain` kuyruğunda). `_firstLoad` bitmeden çalışmaz.
  ///
  /// **Dönüş `null` = merge UYGULANAMADI** (vault kapandı / ilk-load yok / rawStore yok) →
  /// çağıran (TokenSyncService) cursor'u İLERLETMEMELİ (reviewer [P1]: aksi halde remote
  /// satırlar diske yazılmadan cursor ilerler → sonraki pull onları atlar). Non-null
  /// (boş pull'da `none` dahil) = merge ÇALIŞTI, disk tutarlı → cursor ilerleyebilir.
  Future<TokenMergeOutcome?> applyRemoteMerge(
          List<RemoteTokenRow> rows, String? pullCursorIso) =>
      _sequenceValue<TokenMergeOutcome?>(() async {
        final raw = _rawStore;
        if (raw == null || !_firstLoad.isCompleted || isClosed) {
          return null; // merge YAPILAMADI → cursor ilerletilmemeli
        }
        final outcome = await raw.importRemote(rows, pullCursorIso: pullCursorIso);
        if (outcome.changed && !isClosed) {
          await _reloadFromStoreUnsequenced(); // ZATEN sequencer içindeyiz
        }
        return outcome;
      });

  /// Canlı senkron desteği var mı (sync bağlı + uid'li + token_sync_enabled flag açık).
  /// UI toggle'ı bununla gizlenir/gösterilir (flag false → toggle gizli — Adım F).
  bool get syncEnabled => _sync != null && _syncFlagOn;

  /// Settings toggle → canlı senkronu oturum-içi aç (Realtime abone). Flag kapalıysa no-op
  /// (TokenSyncService de gate'li — savunma derinliği).
  void enableLiveSync() {
    if (!_syncFlagOn) return;
    _sync?.enableLive();
  }

  /// Settings toggle → canlı senkronu oturum-içi kapat (catch-up sync devam eder).
  Future<void> disableLiveSync() async => _sync?.disableLive();

  /// Göstergeden manuel "şimdi senkronize et" (opsiyonel). Flag kapalıysa no-op.
  Future<void> syncNow() async {
    if (!_syncFlagOn) return;
    await _sync?.syncOnce();
  }

  /// Diskten yeniden yükle (manuel/test çağrısı). Sequencer ALTINDA çalışır → kullanıcı
  /// mutasyonuyla serileşir; `_firstLoad` tamamlanmadan ÇALIŞMAZ. (Merge yolu
  /// `applyRemoteMerge` import+reload'ı TEK kritik bölümde yapar; bunu ayrıca çağırmaz.)
  Future<void> reloadFromStore() => _sequence(_reloadFromStoreUnsequenced);

  /// Reload çekirdeği — sequencer'a SARMALANMAZ (çağıran zaten kritik bölümde olabilir,
  /// örn. `applyRemoteMerge`). `load()` once-guard'ını BYPASS eder; integrity/corrupted
  /// muhasebesini KORUR; repo cache'ini (`_lastById`) repopulate eder (import sonrası ZORUNLU).
  Future<void> _reloadFromStoreUnsequenced() async {
    if (!_firstLoad.isCompleted) return; // ilk load bitmeden reload yok
    if (isClosed) return;
    final VaultLoadResult result;
    try {
      result = await _repository.load();
    } catch (e) {
      if (!isClosed) emit(state.copyWith(loaded: true, error: e));
      return;
    }
    if (isClosed) return;
    emit(state.copyWith(
      loaded: true,
      accounts: result.accounts,
      corruptedCount: result.corruptedCount,
      clearError: true,
    ));
  }

  /// Bozuk/çözülemeyen kayıtları KALICI siler (yalnız açık kullanıcı onayıyla
  /// çağrılmalı). Ardından yeniden yükler → banner temizlenir. **Sequencer ALTINDA**
  /// (reviewer [P2]: purge disk yazımı sync import / mutasyon ile yarışmasın — tek yazma kuyruğu).
  Future<void> purgeCorrupted() async {
    await _awaitLoaded(); // repo cache (_corruptedRaw) dolu olmalı
    return _sequence(() async {
      if (isClosed) return;
      await _repository.purgeCorrupted();
      await _reloadFromStoreUnsequenced(); // ZATEN sequencer içindeyiz
    });
  }

  Future<void> add(OtpAccount account) async {
    await _awaitLoaded();
    // Faz 3 Patch 4 (Adım E): issuer'ı katalog kanonik adına hizala (no-op'sa değişmez).
    final normalized = _canonicalize(account);
    return _sequence(() async {
      _guardIntegrity();
      await _emitAndPersist([...state.accounts, normalized]);
      _pushAfterMutation();
    });
  }

  /// Faz 5 Patch 1 — toplu ekleme (import). Listenin TAMAMI tek `save` ve tek
  /// push ile yazılır.
  ///
  /// **[add]'e DELEGE EDİLMEZ (plan §3.6 / D7):** `add` her çağrıda tüm listeyi
  /// diske yazar ve ayrı bir push tetikler → N token'lık bir import N kez şifreleme
  /// + N push demek olurdu. Burada tek kritik bölümde tek `_emitAndPersist` +
  /// tek `_pushAfterMutation` var.
  ///
  /// Dedupe ÇAĞIRANIN işi (`ImportService.preview` vault'a karşı zaten eler) —
  /// bu metot aldığı listeyi olduğu gibi, SIRASINI koruyarak ekler.
  Future<void> addAll(List<OtpAccount> accounts) async {
    await _awaitLoaded();
    if (accounts.isEmpty) return; // no-op: yazma da push da yok
    // Adım E ile aynı kanonikleştirme (katalog yoksa no-op).
    final normalized = accounts.map(_canonicalize).toList(growable: false);
    return _sequence(() async {
      _guardIntegrity();
      await _emitAndPersist([...state.accounts, ...normalized]);
      _pushAfterMutation();
    });
  }

  /// Stabil token id'sine göre siler (index değil). Faz 3 Patch 3: sync'li yolda
  /// **soft-delete** (tombstone push edilebilsin); legacy yolda eski hard-remove.
  Future<void> removeById(String id) async {
    await _awaitLoaded();
    return _sequence(() async {
      _guardIntegrity();
      if (!state.accounts.any((a) => a.id == id)) return; // bulunamadı → no-op
      final next = state.accounts.where((a) => a.id != id).toList();

      final rawStore = _rawStore;
      if (_sync != null && rawStore != null) {
        // ATOMİK: markDeleted ÖNCE (son blob'la tombstone üretir + diske yazar);
        // _emitAndPersist/save ÇAĞIRMA (save listede-olmayan id'nin blob'unu düşürürdü).
        await rawStore.markDeleted(id);
        emit(state.copyWith(accounts: next));
        _pushAfterMutation();
      } else {
        // Legacy (sync yok) → eski hard-remove davranışı (regresyon yok).
        await _emitAndPersist(next);
      }
    });
  }

  /// HOTP sayaç artırma. id-bazlı.
  Future<void> incrementCounter(String id) async {
    await _awaitLoaded();
    return _sequence(() async {
      _guardIntegrity();
      var changed = false;
      final next = [
        for (final a in state.accounts)
          if (a.id == id && a.type == OtpType.hotp)
            (changed = true) ? a.copyWith(counter: a.counter + 1) : a
          else
            a,
      ];
      if (!changed) return; // hedef HOTP yok → no-op
      await _emitAndPersist(next);
      _pushAfterMutation();
    });
  }

  /// Bütünlük hatası state'inde mutasyonu reddeder (review P1 — kritik).
  void _guardIntegrity() {
    if (state.error != null) {
      throw StateError(
          'Vault bütünlük hatası state\'inde — değişiklik kaydedilemez. '
          'Önce vault\'u yeniden aç veya sıfırla.');
    }
  }

  /// add/edit/increment sonrası best-effort push (delete kendi push'unu yapar).
  void _pushAfterMutation() {
    _sync?.pushChanged().ignore();
  }

  /// State'i günceller ve depoya yazar. **Optimistic** (offline-first): UI önce
  /// güncellenir (kullanıcı görünür kaybı yaşamasın), ardından kalıcılaştırılır.
  /// Yazma hatası state'i geri ALMAZ ama **sessizce yutulmaz** — çağırana
  /// (mutasyon metodu → UI) yukarı fırlar, UI SnackBar gösterir. Bu davranış
  /// vault_cubit_test ile sabitlenmiştir.
  Future<void> _emitAndPersist(List<OtpAccount> accounts) async {
    emit(state.copyWith(loaded: true, accounts: accounts));
    await _repository.save(accounts);
  }

  @override
  Future<void> close() {
    // Faz 3 Patch 3 — subtree teardown (lock/arka-plan/signOut) → Realtime aboneliğini
    // kapat (abone-on-unlock / unsubscribe-on-lock subtree lifecycle'a bağlı).
    _sync?.dispose().ignore();
    return super.close();
  }
}
