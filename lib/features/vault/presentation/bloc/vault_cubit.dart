/// Vault durumu — kayıtlı OTP hesaplarının listesi.
///
/// Faz 1: token'lar `VaultRepository` (flutter_secure_storage) ile cihazda
/// kalıcı; her mutasyon sonrası kaydedilir. Faz 2: repository katmanı aynı
/// kalır, altına masterKey ile E2E şifreleme eklenir.
library;

import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/otp/otp_account.dart';
import '../../data/vault_load_result.dart';
import '../../data/vault_repository.dart';

class VaultState extends Equatable {
  /// İlk yükleme tamamlandı mı (depodan okuma). UI splash/boş-durum ayrımı için.
  final bool loaded;
  final List<OtpAccount> accounts;

  /// Çözülemeyen/atlanan bozuk kayıt sayısı (kısmi bozulma). >0 → UI banner.
  final int corruptedCount;

  /// Yükleme/bütünlük hatası (örn. tüm kayıtlar decrypt fail → integrity).
  /// Set ise UI "boş vault" yerine bütünlük hata ekranı gösterir.
  final Object? error;

  const VaultState({
    this.loaded = false,
    this.accounts = const [],
    this.corruptedCount = 0,
    this.error,
  });

  VaultState copyWith({
    bool? loaded,
    List<OtpAccount>? accounts,
    int? corruptedCount,
    Object? error,
    bool clearError = false,
  }) =>
      VaultState(
        loaded: loaded ?? this.loaded,
        accounts: accounts ?? this.accounts,
        corruptedCount: corruptedCount ?? this.corruptedCount,
        error: clearError ? null : (error ?? this.error),
      );

  @override
  List<Object?> get props => [loaded, accounts, corruptedCount, error];
}

class VaultCubit extends Cubit<VaultState> {
  final VaultRepository _repository;

  VaultCubit(this._repository) : super(const VaultState());

  /// İlk `load()` tamamlanma sinyali. Mutasyonlar (add/remove/increment) bunu
  /// bekler → henüz okunmamış depo kayıtlarını `save()` ile EZMEZ (review P1).
  ///
  /// Kök sebep: `save()` yalnız o anki `accounts` + repo'nun load'da dolan
  /// bellek cache'i (`_lastById`/`_corruptedRaw`) üzerinden yazar. Load bitmeden
  /// save edilirse diskteki şifreli kayıtlar (henüz okunmamış) kaybolur — bellek
  /// merge bunu düzeltemez (disk zaten ezilmiştir). Çözüm: mutasyonu load'a
  /// sıralamak (kuyruğa almak yerine basitçe beklemek; tek ilk-yükleme).
  final Completer<void> _firstLoad = Completer<void>();

  /// `load()` çağrıldı mı (idempotency + mutasyon-önce-load tetikleme için).
  bool _loadStarted = false;

  /// İlk `load()`'ı bekler. Normalde açılışta `..load()` çağrılır; çağrılmadıysa
  /// (örn. doğrudan `add` ile başlayan akış/test) mutasyon load'ı kendi tetikler
  /// → deadlock olmaz, yine de okunmamış depoyu ezmez.
  Future<void> _awaitLoaded() {
    if (!_loadStarted) {
      // load()'ı başlat ama beklemesini ayrı tut (load kendi await'ini yapar).
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
    emit(VaultState(
      loaded: true,
      accounts: result.accounts,
      corruptedCount: result.corruptedCount,
    ));
    if (!_firstLoad.isCompleted) _firstLoad.complete();
  }

  /// Bozuk/çözülemeyen kayıtları KALICI siler (yalnız açık kullanıcı onayıyla
  /// çağrılmalı). Ardından yeniden yükler → banner temizlenir.
  Future<void> purgeCorrupted() async {
    await _awaitLoaded(); // repo cache (_corruptedRaw) dolu olmalı
    await _repository.purgeCorrupted();
    final result = await _repository.load();
    emit(VaultState(
      loaded: true,
      accounts: result.accounts,
      corruptedCount: result.corruptedCount,
    ));
  }

  Future<void> add(OtpAccount account) async {
    // İlk load bitmeden ekleme depodaki okunmamış kayıtları ezerdi (review P1).
    await _awaitLoaded();
    _guardIntegrity();
    await _emitAndPersist([...state.accounts, account]);
  }

  /// Stabil token id'sine göre siler (index değil — liste reorder/eşzamanlı
  /// değişimde yanlış öğeyi silmeyi önler).
  Future<void> removeById(String id) async {
    await _awaitLoaded();
    _guardIntegrity();
    final next = state.accounts.where((a) => a.id != id).toList();
    if (next.length == state.accounts.length) return; // bulunamadı → no-op
    await _emitAndPersist(next);
  }

  /// HOTP sayaç artırma (kod isteğe bağlı yenilenir). id-bazlı.
  Future<void> incrementCounter(String id) async {
    await _awaitLoaded();
    _guardIntegrity();
    var changed = false;
    final next = [
      for (final a in state.accounts)
        if (a.id == id && a.type == OtpType.hotp)
          (changed = true) ? a.copyWith(counter: a.counter + 1) : a
        else
          a,
    ];
    if (!changed) return; // hedef HOTP yok → no-op (gereksiz yazma yapma)
    await _emitAndPersist(next);
  }

  /// Bütünlük hatası state'inde mutasyonu reddeder (review P1 — kritik).
  ///
  /// Top-level bozulma / tüm-kayıt decrypt-fail durumunda `load()` erken fırlar:
  /// `state.accounts` boş VE repo'nun bozuk-kayıt cache'i (`_corruptedRaw`) BOŞ
  /// kalır (load repopulate edemeden çıktı). Bu state'te bir `save()` çalışırsa
  /// diskteki bozuk-ama-belki-kurtarılabilir ham vault'u, kullanıcının açık
  /// "Vault'u sıfırla" onayı OLMADAN ezer. Mutasyonu burada durdur → UI
  /// `_runMutation`/`_addAndClose` bunu yakalar ve SnackBar gösterir.
  void _guardIntegrity() {
    if (state.error != null) {
      throw StateError(
          'Vault bütünlük hatası state\'inde — değişiklik kaydedilemez. '
          'Önce vault\'u yeniden aç veya sıfırla.');
    }
  }

  /// State'i günceller ve depoya yazar. Yazma hatası state'i geri almaz
  /// (bellek-içi doğru kalır); kalıcılık bir sonraki başarılı mutasyonda yakalar.
  Future<void> _emitAndPersist(List<OtpAccount> accounts) async {
    emit(state.copyWith(loaded: true, accounts: accounts));
    await _repository.save(accounts);
  }
}
