/// Vault kilit/oturum durum makinesi (Faz 2 Patch 4).
///
/// Durumlar:
///   - `uninitialized`        : key attributes yok → setup akışı.
///   - `setupPending`         : setup üretildi, recovery verify bekliyor. masterKey
///                              + attrs + mnemonic BELLEKTE, henüz diske YAZILMADI.
///   - `locked`               : attrs var, masterKey bellekte yok → unlock.
///   - `unlocked`             : masterKey bellekte → vault.
///   - `locking`              : geçiş — unlocked subtree teardown ediliyor; masterKey
///                              hâlâ canlı ama tüketici yok. Sonra dispose → locked.
///   - `keyAttributesCorrupted`: açılışta attrs okunamadı (parse hatası).
///
/// **Key sahipliği — tek model (review P2):** unlocked iken masterKey `KeyHandle`'ın
/// sahibi BU cubit'tir; `EncryptedVaultRepository` ona yalnız referans tutar (handle'ı
/// dispose ETMEZ). Lock akışı: `locking` (subtree/`VaultCubit` dispose) → SONRA
/// `masterKey.dispose()` → `locked`. Böylece "use-after-free" ve "locked'ta key canlı"
/// invariant ihlali İKİSİ DE önlenir. `locked`/`uninitialized`/`keyAttributesCorrupted`
/// state'lerinde masterKey GARANTİ null.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/crypto/crypto_exceptions.dart';
import '../../../../core/crypto/key_attributes.dart';
import '../../../../core/crypto/key_handle.dart';
import '../../../auth/domain/biometric_exceptions.dart';
import '../../../auth/domain/biometric_service.dart';
import '../../../auth/domain/key_manager.dart';
import '../../../account/data/attrs_dirty_store.dart';
import '../../../account/data/reset_pending_store.dart';
import '../../../account/domain/key_attributes_repository.dart';
import '../../../account/domain/sync_exceptions.dart';
import '../../../vault/domain/remote_token_repository.dart';
import '../../data/key_attributes_store.dart';
import 'vault_lock_state.dart';

/// Reset edilebilecek tüm vault storage anahtarları (reset semantiği — review P2 #5).
/// Tek kaynak: hem `VaultLockCubit.resetVault` hem testler buradan okur.
class VaultStorageKeys {
  static const encryptedVault = 'vault_encrypted_v1';
  static const keyAttributes = KeyAttributesStore.storageKey;
  static const plaintextVault = 'vault_accounts_v1';
  static const migrationMarker = 'vault_migration_v1';
  static const viewMode = 'vault_view_mode_v1';

  /// Faz 3 Patch 3 — token sync cursor + canlı-senkron tercihi + key_attributes
  /// dirty (changePassword retry) marker'ı. Hepsi per-uid (reset namespace'i temizler).
  static const tokenSyncCursor = 'token_sync_cursor_v1';
  static const liveSyncEnabled = 'live_sync_enabled_v1';
  static const attrsDirty = 'attrs_dirty_v1';

  /// Patch 5: biyometrik anahtar. Ayrı options'lı/namespace'li storage'da olduğu
  /// için `_deleteKeys` (default storage) ona ULAŞAMAYABİLİR → asıl temizlik
  /// `resetVault` içinde `biometric.disable()` ile yapılır. Burada listede olması
  /// savunma katmanı (default storage'a düşmüş bir kalıntı için).
  static const biometricKey = 'vault_biometric_key_v1';

  static const all = [
    encryptedVault,
    keyAttributes,
    plaintextVault,
    migrationMarker,
    viewMode,
    tokenSyncCursor,
    liveSyncEnabled,
    attrsDirty,
    biometricKey,
  ];

  /// Faz 3 Patch 1 — bir uid namespace'inin SİLİNEBİLİR anahtarları (reset). Prefix
  /// uygulanan vault anahtarları (`plaintextVault` GLOBAL/uid-siz olduğu için DAHİL
  /// EDİLMEZ — başka namespace'leri etkilemesin). `biometricKey` ayrı OS-keystore'da
  /// → asıl temizlik `biometric.disable()` (burada savunma katmanı).
  static List<String> forUser(String prefix) => [
        '$prefix$encryptedVault',
        '$prefix$keyAttributes',
        '$prefix$migrationMarker',
        '$prefix$viewMode',
        '$prefix$tokenSyncCursor',
        '$prefix$liveSyncEnabled',
        '$prefix$attrsDirty',
        biometricKey,
      ];
}

/// Migration'ı `VaultCubit.load()`'tan ÖNCE çalıştırmak için soyut kanca. unlock /
/// commitSetup / recover yollarında çağrılır. (Gerçek impl `VaultMigration`'ı sarar;
/// test sahte verir.)
typedef MigrationRunner = Future<void> Function(KeyHandle masterKey);

class VaultLockCubit extends Cubit<VaultLockState> {
  final KeyManager _keyManager;
  final KeyAttributesStore _attrsStore;
  final MigrationRunner _migrate;
  final BiometricService _biometric;

  /// Reset / view-mode için storage anahtarlarını silen kanca (DI'dan; testte sahte).
  final Future<void> Function(List<String> keys) _deleteKeys;

  /// Patch 5 — biyometri state alanları (tüm `locked`/`unlocked` emit'lerine bu
  /// field'lardan beslenir; helper `_locked`/`_unlocked` tek noktadan tutarlılık
  /// sağlar — reviewer 4.tur [P1]). `_biometricEnrolled` = `attrs.bmk != null`;
  /// `_deviceBiometricAvailable` = cihaz yeteneği (enrollment'tan bağımsız).
  bool _biometricEnrolled = false;
  bool _deviceBiometricAvailable = false;

  /// Biyometri prompt'u (`storage.read` OS geçidi) DEVAM ediyor mu? (reviewer 2.tur [P1])
  /// Sistem biyometri prompt'u açılırken app kısa süre `inactive` üretebilir; bu flag
  /// true iken `inactive` abort'tan MUAF tutulur (başarılı unlock yarıda kesilmesin).
  /// `paused` (gerçek arka plan) YİNE kesin abort eder. `_commitInFlight` simetriği.
  bool _biometricPromptInFlight = false;

  /// Oturum içi masterKey — yalnız `unlocked`/`setupPending`/`locking` state'lerinde
  /// non-null. Çift-dispose guard idempotent (`KeyHandle.dispose` zaten idempotent).
  KeyHandle? _masterKey;

  /// `setupPending` sırasında bellekte tutulan (henüz persist edilmemiş) attrs.
  KeyAttributes? _pendingAttrs;

  /// **Arka-plan-yarışı guard'ı (review P1):** uzun süren bir hassas async işlem
  /// (`unlock` Argon2id / `commitSetup` / `recoverWithNewPassword` + migration)
  /// devam ederken app arka plana geçerse `onAppBackgrounded` bunu `true` yapar.
  /// İşlem tamamlanırken `unlocked` emit etmeden ÖNCE bu bayrak kontrol edilir →
  /// set ise key dispose edilir ve `unlocked`'a GEÇİLMEZ (arka planda kilitli kalır).
  /// Her hassas işlemin başında sıfırlanır.
  bool _abortToBackground = false;

  /// `commitSetup` async işlemi sürüyor mu? (review P1) Arka plana geçişte
  /// `setupPending` görüldüğünde, devam eden bir commit varsa state'i commit
  /// kendisi sonlandırır (attrs yazıldıysa `locked`); yoksa `cancelSetup`.
  bool _commitInFlight = false;

  /// Faz 3 Patch 2 — sunucu `key_attributes` deposu + aktif uid. **Opsiyonel:**
  /// null (legacy/uid-siz vault, Patch 1 testleri) → restore/upload NO-OP, eski
  /// davranış birebir korunur (regresyon yok). Dolu → bootstrap'ta restore + unlocked'ta backfill.
  final KeyAttributesRepository? _remoteRepo;
  final String? _uid;

  /// Security review finding 1 — server-side token store, used ONLY to wipe this
  /// uid's remote rows on [resetVault]. Optional (null → legacy/uid-less/tests,
  /// remote wipe is a no-op; previous behaviour preserved). Not used for sync
  /// (that lives in [TokenSyncService] under VaultCubit) — reset is its only job here.
  final RemoteTokenRepository? _remoteTokenRepo;

  /// Faz 3 Patch 3 (Adım K) — changePassword sonrası sunucu UPDATE'i ağ hatasına
  /// düşerse SET kalır → unlock'ta dirty-replay yeniden dener. Opsiyonel (null →
  /// retry yok; eski testler/legacy etkilenmez).
  final AttrsDirtyStore? _attrsDirtyStore;

  /// Security review finding 1 (round 2) — when [resetVault]'s remote tombstone
  /// fails offline, this records the reset instant so a later signed-in unlock can
  /// retry (tombstoning only pre-reset rows). Optional (null → no retry; legacy/tests).
  final ResetPendingStore? _resetPendingStore;

  VaultLockCubit({
    required KeyManager keyManager,
    required KeyAttributesStore attrsStore,
    required MigrationRunner migrate,
    required BiometricService biometric,
    required Future<void> Function(List<String> keys) deleteKeys,
    KeyAttributesRepository? remoteRepo,
    RemoteTokenRepository? remoteTokenRepo,
    String? uid,
    AttrsDirtyStore? attrsDirtyStore,
    ResetPendingStore? resetPendingStore,
  })  : _keyManager = keyManager,
        _attrsStore = attrsStore,
        _migrate = migrate,
        _biometric = biometric,
        _deleteKeys = deleteKeys,
        _remoteRepo = remoteRepo,
        _remoteTokenRepo = remoteTokenRepo,
        _uid = uid,
        _attrsDirtyStore = attrsDirtyStore,
        _resetPendingStore = resetPendingStore,
        super(const VaultLockState.uninitialized());

  /// `locked` emit'i biyometri field'larını taşıyarak yapar (tek nokta — reviewer 4.tur [P1]).
  VaultLockState _locked({VaultLockError? error}) => VaultLockState.locked(
        error: error,
        biometricEnrolled: _biometricEnrolled,
        deviceBiometricAvailable: _deviceBiometricAvailable,
      );

  /// `unlocked` emit'i biyometri field'larını taşıyarak yapar (tek nokta — reviewer 4.tur [P1]).
  VaultLockState _unlocked() => VaultLockState.unlocked(
        biometricEnrolled: _biometricEnrolled,
        deviceBiometricAvailable: _deviceBiometricAvailable,
      );

  /// Biyometri field'larını mevcut attrs + cihaz yeteneğinden günceller. unlock/
  /// commitSetup/recover/bootstrap sonrası çağrılır → her emit doğru değeri taşır.
  Future<void> _refreshBiometricState(KeyAttributes? attrs) async {
    _biometricEnrolled = attrs?.biometricEncryptedMasterKey != null;
    _deviceBiometricAvailable = await _biometric.isAvailable();
  }

  /// Oturum içi masterKey'i UI subtree'sine (EncryptedVaultRepository kurmak için)
  /// vermek için. Yalnız `unlocked` iken çağrılmalı; sahiplik BU cubit'te kalır.
  KeyHandle get masterKey {
    final k = _masterKey;
    if (k == null) {
      throw StateError('masterKey yok (state=${state.status})');
    }
    return k;
  }

  /// Açılış: attrs var mı? Parse hatası → keyAttributesCorrupted.
  ///
  /// Not (iOS Keychain): `flutter_secure_storage` veriyi Keychain'e yazar ve
  /// Keychain item'ları uygulama silinince OS tarafından SİLİNMEZ (Apple'ın
  /// bilinçli tasarımı). Yani app silinip yeniden kurulsa bile eski attrs kalabilir
  /// → kullanıcı yine unlock ekranı görür. Bu davranış bilinçli korunur (otomatik
  /// reinstall-reset, mevcut kullanıcıların verisini riske atmadan ayırt edilemez
  /// — bkz. CHANGELOG 2026-06-07). Kullanıcı isterse "Vault'u sıfırla" ile temizler.
  Future<void> bootstrap() async {
    try {
      final attrs = await _attrsStore.read();
      if (attrs != null) {
        // LOKAL VAR → Patch 1 davranışı AYNEN (restore fetch ATLANIR).
        // Patch 5: biyometri enrolled mı (attrs.bmk) + cihaz uygun mu → state'e taşı.
        await _refreshBiometricState(attrs);
        emit(_locked());
        return;
      }
      // Lokal attrs YOK. Faz 3 Patch 2: sunucudan restore dene (uid varsa).
      if (_remoteRepo == null || _uid == null) {
        // legacy/uid-siz/test → restore yok → setup.
        emit(const VaultLockState.uninitialized());
        return;
      }
      await _restoreFromRemote();
    } on FormatException {
      emit(const VaultLockState.keyAttributesCorrupted());
    }
  }

  /// Faz 3 Patch 2 — yeni cihazda sunucudan `key_attributes` restore.
  ///
  /// **KRİTİK (review [P1] #1):** fetch BAŞLAMADAN ÖNCE `restoring` emit edilir →
  /// router `/splash`'e tutar, kullanıcı fetch sürerken `/setup` GÖRMEZ (yeni vault
  /// kuramaz). Sonuç:
  /// - remote VAR → lokale yaz + `locked` (mevcut unlock akışı master parolayı sorar).
  /// - remote 0-row (gerçekten yeni hesap) → `uninitialized` (setup).
  /// - ağ/RLS/format hatası ([SyncError]) → `restoreFailed` (setup'a DÜŞMEZ → çift-vault yok).
  /// - lokal finalize hatası (Keychain/Keystore IO `write`) → YİNE `restoreFailed` (reviewer
  ///   [P2]): aksi halde hata `bootstrap` future'ından kabarıp state `restoring`'te ASILI kalırdı
  ///   (router `/splash`'te takılır, kullanıcının retry yolu yok). Güvenli + retry edilebilir state.
  Future<void> _restoreFromRemote() async {
    final repo = _remoteRepo;
    final uid = _uid;
    if (repo == null || uid == null) {
      emit(const VaultLockState.uninitialized());
      return;
    }
    emit(const VaultLockState.restoring()); // fetch ÖNCESİ → /setup görünmez
    try {
      final remote = await repo.fetch(uid);
      if (remote == null) {
        emit(const VaultLockState.uninitialized()); // gerçek 0-row → setup
        return;
      }
      await _attrsStore.write(remote); // server-wins: lokale yaz (IO hatası fırlatabilir)
      await _refreshBiometricState(remote);
      emit(_locked()); // master parola sorulur (mevcut unlock)
    } on SyncError {
      emit(const VaultLockState.restoreFailed()); // ağ/RLS → setup'a DÜŞME
    } catch (_) {
      // SyncError DIŞI beklenmeyen hata (lokal secure-storage write IO / biyometri availability).
      // `restoring`'te asılı kalma → güvenli `restoreFailed` (retry edilebilir; setup'a DÜŞMEZ).
      emit(const VaultLockState.restoreFailed());
    }
    // (FormatException repository içinde SyncMalformedRemote'a çevrilir → buraya SyncError gelir.)
  }

  /// `restoreFailed`'dan yeniden restore dener (RestoreFailedPage "Tekrar dene").
  Future<void> retryRestore() async {
    if (state.status != VaultLockStatus.restoreFailed) return;
    await _restoreFromRemote();
  }

  /// Faz 3 Patch 2 — unlocked olunca best-effort backfill (kullanıcı kararı 4/5).
  ///
  /// GUARD'LI insert: sunucuda kayıt VARSA üzerine YAZMA (server-wins; changePassword
  /// gibi kasıtlı değişiklik Patch 3 `updated_at` LWW). Best-effort: kullanıcıyı
  /// BLOKLAMAZ, hata SESSİZ yutulur (sync zorunlu değil, vault lokalde çalışır).
  /// **Yalnız zaten-şifreli attrs gider; masterKey/KEK/secret ASLA.**
  Future<void> _backfillRemote() async {
    final repo = _remoteRepo;
    final uid = _uid;
    if (repo == null || uid == null) return; // legacy/uid-siz → no-op
    try {
      if (await repo.existsRemote(uid)) return; // server-wins guard
      final attrs = await _attrsStore.read();
      if (attrs != null) await repo.upload(uid, attrs);
    } catch (_) {
      // best-effort: ağ/izin hatası kullanıcıyı etkilemez; bir sonraki unlocked'ta yeniden denenir.
    }
  }

  /// Faz 3 Patch 3 (Adım K) — changePassword/recovery-new-password sonrası sunucudaki
  /// `key_attributes` satırını GÜNCELLER (sunucu sarmalı eski parolada kalmasın → yeni
  /// cihazda fresh-restore yeni parolayı kullanır). masterKey DEĞİŞMEZ → token re-encrypt YOK.
  /// Best-effort: ağ hatası → `attrsDirty` marker SET kalır (unlock'ta dirty-replay tekrar dener);
  /// başarı → marker CLEAR. existsRemote'a göre update (varsa) / upload (ilk insert).
  Future<void> _syncAttrsAfterPasswordChange() async {
    final repo = _remoteRepo;
    final uid = _uid;
    if (repo == null || uid == null) return; // legacy/uid-siz → no-op
    try {
      final attrs = await _attrsStore.read();
      if (attrs == null) return;
      if (await repo.existsRemote(uid)) {
        await repo.update(uid, attrs); // changePassword → UPDATE (LWW)
      } else {
        await repo.upload(uid, attrs); // hiç yoksa ilk insert
      }
      await _attrsDirtyStore?.clear(); // başarı → marker temizle
    } catch (_) {
      // marker SET kalır (recoverWithNewPassword set etti) → unlock'ta yeniden denenir.
    }
  }

  /// Unlock/bootstrap-locked-finalize sonrası: dirty marker SET ise sunucu sarmalını
  /// yeniden yazmayı dener (changePassword ağ hatasının gerçek retry'ı). Best-effort.
  Future<void> _replayDirtyAttrsIfNeeded() async {
    final dirtyStore = _attrsDirtyStore;
    if (dirtyStore == null || _remoteRepo == null || _uid == null) return;
    try {
      if (await dirtyStore.isDirty()) {
        await _syncAttrsAfterPasswordChange();
      }
    } catch (_) {
      // best-effort.
    }
  }

  // --- Setup akışı (recovery DOĞRULANMADAN persist YOK) ---

  /// SetupPassword → masterKey + attrs + mnemonic üretir; DİSKE YAZMAZ. Recovery
  /// göster/doğrula ekranları bu state üzerinden ilerler.
  Future<void> beginSetup(String masterPassword) async {
    // Setup restart (review P2): önceki pending masterKey varsa dispose et —
    // doğrudan üzerine yazmak eski handle'ı sızdırırdı.
    _disposeKey();
    _abortToBackground = false; // hassas işlem başı (review P1 — KeyManager.setup async)
    final result = await _keyManager.setup(masterPassword);
    // Arka-plan yarışı (review P1): Argon2id/KEK türetimi sürerken app background
    // olduysa masterKey + mnemonic'i BELLEKTE TUTMA → üretileni hemen dispose et,
    // uninitialized kal (ARCHITECTURE §2.3: arka plana geçince temizlenir). Diske
    // zaten hiçbir şey yazılmadı (setup commit recovery-verify'da olur).
    if (_abortToBackground) {
      _abortToBackground = false;
      result.masterKey.dispose();
      emit(const VaultLockState.uninitialized());
      return;
    }
    _masterKey = result.masterKey;
    _pendingAttrs = result.attrs;
    emit(VaultLockState.setupPending(mnemonic: result.recoveryMnemonic));
  }

  /// RecoveryKeyVerify başarılı → SETUP COMMIT noktası. attrs yazılır →
  /// migration (load'dan ÖNCE) → unlocked. Verify bitmeden çıkışta hiçbir şey
  /// persist edilmemiştir ([cancelSetup] / lifecycle ile temizlenir).
  Future<void> commitSetup() async {
    final attrs = _pendingAttrs;
    final key = _masterKey;
    if (attrs == null || key == null) {
      throw StateError('commitSetup: setupPending değil');
    }
    _abortToBackground = false; // hassas işlem başı (review P1)
    _commitInFlight = true;
    try {
      // 1) attrs DİSKE YAZ. Bu noktaya kadar diske HİÇBİR ŞEY persist edilmemiştir.
      //    write fail ederse (secure storage IO hatası) → vault KURULMADI →
      //    key dispose + pending temizle + `uninitialized` (review P2 2.tur: eskiden
      //    write fail'de hiçbir cleanup yoktu, finally yalnız _commitInFlight'ı
      //    sıfırlıyordu → masterKey/pending/setupPending arka planda canlı kalırdı).
      try {
        await _attrsStore.write(attrs);
      } catch (_) {
        _disposeKey();
        _pendingAttrs = null;
        emit(const VaultLockState.uninitialized()); // diske yazılmadı → kurulmadı
        rethrow;
      }
      // Setup attrs'ında bmk yok → enrolled=false; cihaz yeteneğini hesapla ki
      // unlocked sonrası Settings'ten biyometri açılabilsin (reviewer 4.tur [P1]).
      await _refreshBiometricState(attrs);
      // 2) attrs DİSKE YAZILDI: vault GERÇEKTEN var. Bundan sonra hata olsa bile
      //    setupPending/uninitialized'a GERİ DÖNME → `locked` (vault kurulu; migration
      //    commit-marker'lı/idempotent → sonraki unlock yeniden dener). Hata rethrow.
      try {
        await _migrate(key); // migration VaultCubit.load()'dan ÖNCE bitmeli
      } catch (_) {
        _disposeKey();
        _pendingAttrs = null;
        emit(_locked());
        rethrow;
      }
      _pendingAttrs = null;
      // commitSetup'ta key zaten _masterKey'in sahibi (setupPending'den). Arka-plan
      // yarışı: işlem sürerken background olduysa unlocked'a GEÇME. attrs DİSKE
      // YAZILDI (write tamamlandı) → vault var → doğru arka-plan state'i `locked`.
      if (_abortToBackground) {
        _abortToBackground = false;
        _disposeKey();
        emit(_locked());
        return;
      }
      emit(_unlocked());
      // Push the new vault's attrs to the server. Use update-if-exists (not the
      // insert-once backfill) so a fresh setup AFTER a reset overwrites the stale
      // server-wrapped masterKey instead of being blocked by the server-wins
      // guard (security review finding 1). At commitSetup the local attrs are
      // authoritative for this uid: had the server held a real vault, bootstrap
      // would have restored it rather than routing here to setup. Best-effort.
      unawaited(_syncAttrsAfterPasswordChange());
      // Finding 1 (round 2): if a prior reset couldn't tombstone the server, retry
      // now (cut off at the reset instant so THIS new vault's tokens are spared).
      unawaited(_replayResetTombstoneIfNeeded());
    } finally {
      _commitInFlight = false;
    }
  }

  /// Setup iptal / verify FAIL / setup restart → pending masterKey + mnemonic
  /// temizlenir, state uninitialized (diske hiçbir şey yazılmamıştır).
  void cancelSetup() {
    _disposeKey();
    _pendingAttrs = null;
    emit(const VaultLockState.uninitialized());
  }

  // --- Unlock akışı ---

  /// Master parola ile aç. Yanlış parola → state'te hata (kilitli kalır).
  ///
  /// **Key lifecycle (review P1):** masterKey'i ancak migration başarıyla bittikten
  /// SONRA `_masterKey`'e sahiplendir + `unlocked` emit et. Migration fırlatırsa
  /// (decrypt/IO) key `finally`'de dispose edilir → "locked state'te canlı key"
  /// invariant'ı korunur (kabaran exception caller'a gider, `locked` kalırız).
  Future<void> unlock(String password) async {
    _abortToBackground = false; // hassas işlem başı (review P1)
    final attrs = await _readAttrsOrThrow();
    await _refreshBiometricState(attrs); // biyometri state'i (her emit'e taşınır)
    final KeyHandle key;
    try {
      key = await _keyManager.unlock(attrs, password);
    } on WrongPasswordException {
      emit(_locked(error: VaultLockError.wrongPassword));
      return;
    }
    var owned = false;
    try {
      await _migrate(key); // crash sonrası yarım migration unlock yolunda tamamlanır
      // Arka-plan yarışı (review P1): Argon2/migration sürerken app background
      // olduysa key'i sahiplenme + unlocked emit ETME → arka planda kilitli kal.
      if (_abortToBackground) {
        _abortToBackground = false;
        emit(_locked());
        return; // finally key'i dispose eder (owned=false)
      }
      _masterKey = key;
      owned = true;
      emit(_unlocked());
      unawaited(_backfillRemote()); // Patch 2: backfill (best-effort, guard'lı)
      // Patch 3 (Adım K): önceki changePassword sunucuya yazılamadıysa (dirty) yeniden dene.
      unawaited(_replayDirtyAttrsIfNeeded());
      // Finding 1 (round 2): retry an offline reset's owed remote tombstone.
      unawaited(_replayResetTombstoneIfNeeded());
    } finally {
      if (!owned) key.dispose(); // migration fail / background-abort → key sızmaz
    }
  }

  /// Recovery mnemonic + YENİ parola TEK atomik çağrı: recoverUnlock → changePassword
  /// → persist → migration → unlocked. Arada bekleyen masterKey state'i OLUŞMAZ.
  Future<void> recoverWithNewPassword(
      List<String> mnemonic, String newPassword) async {
    _abortToBackground = false; // hassas işlem başı (review P1)
    final attrs = await _readAttrsOrThrow();
    KeyHandle? key;
    var owned = false; // sahiplik _masterKey'e geçti mi (geçtiyse finally dispose etmez)
    try {
      key = await _keyManager.recoverUnlock(attrs, mnemonic);
      final newAttrs =
          await _keyManager.changePassword(attrs, key, newPassword);
      await _attrsStore.write(newAttrs);
      // Faz 3 Patch 3 (Adım K): parola değişti → sunucu sarmalı GÜNCELLENMELİ. Marker
      // SET (ağ hatasında unlock'ta dirty-replay yeniden dener); başarıda _sync... clear eder.
      await _attrsDirtyStore?.setDirty();
      await _refreshBiometricState(newAttrs); // bmk korunmuşsa enrolled true kalır
      // Migration BAŞARIYLA bitmeden sahiplenme (review P1): _migrate fırlatırsa
      // key finally'de dispose edilir, _masterKey null kalır (locked invariant'ı korunur).
      await _migrate(key);
      // Arka-plan yarışı (review P1): işlem sürerken app background olduysa
      // unlocked'a GEÇME → arka planda kilitli kal (key finally'de dispose).
      if (_abortToBackground) {
        _abortToBackground = false;
        emit(_locked());
        return;
      }
      _masterKey = key;
      owned = true;
      emit(_unlocked());
      // Patch 3 (Adım K): parola değişti → sunucu sarmalını GÜNCELLE (best-effort;
      // _backfillRemote DEĞİL — o insert-once guard'lı, var olan satırı güncellemez).
      unawaited(_syncAttrsAfterPasswordChange());
    } on WrongRecoveryKeyException {
      emit(_locked(error: VaultLockError.wrongRecovery));
    } on WeakPasswordException {
      emit(_locked(error: VaultLockError.weakPassword));
    } finally {
      if (!owned) key?.dispose(); // hata/iptal/migration-fail yolunda ara key sızmaz
    }
  }

  // --- Lock / lifecycle ---

  /// Kilitle — tek sahiplik modeli: `locking` emit (guard subtree/`VaultCubit`'i
  /// söker, repo referansı bırakılır) → SONRA (bir sonraki frame, teardown bitince)
  /// `masterKey.dispose()` → `locked`. Böylece repo async encrypt/decrypt yaparken
  /// `SecureKey` dispose edilmez (use-after-free yok).
  ///
  /// **[immediate] (review P2):** arka plana geçişte (`onAppBackgrounded`) frame
  /// GARANTİ DEĞİLDİR (paused'ta engine frame çizmeyebilir) → post-frame dispose
  /// asılı kalır, key bellekte kalırdı. Bu yolda `immediate: true` ile key SENKRON
  /// dispose edilir (güvenlik > use-after-free naziklik'i; repo'nun yarıda kalan
  /// async yazısı zaten unchanged-blob + bozuk-kayıt korumasıyla veri kaybetmez).
  /// İnteraktif "Kilitle" butonunda `immediate: false` → frame'li yumuşak teardown.
  void lock({bool immediate = false}) {
    if (state.status != VaultLockStatus.unlocked) return;
    emit(const VaultLockState.locking());
    if (immediate) {
      _disposeKey(); // arka plan: frame bekleme — güvenlik öncelikli (review P2)
      emit(_locked());
      return;
    }
    // İnteraktif: subtree teardown router redirect ile başlar; sonraki frame'de dispose.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isClosed) return;
      // Frame gelmeden background olduysa onAppBackgrounded zaten senkron dispose
      // edip `locked`'a geçmiştir (review P1/P2) → bu stale callback no-op.
      if (state.status != VaultLockStatus.locking) return;
      _disposeKey();
      emit(_locked());
    });
  }

  /// Lifecycle `paused`/`inactive` (review #10 + P2 #3): masterKey'i HER durumda
  /// arka planda bellekten siler (ARCHITECTURE §2.3: "arka plana/kilide geçince
  /// temizlenir").
  ///
  /// - `unlocked` → [lock]`(immediate: true)`: SENKRON dispose (review P2 — frame
  ///   garanti değil; post-frame'e bel bağlamak key'i arka planda canlı bırakırdı).
  /// - `setupPending` → pending temizle (key tüketicisi yok → hemen güvenli).
  /// - `locking` → interaktif `lock()` post-frame dispose'u KUYRUKTA; frame gelmezse
  ///   key asılı kalırdı (review P1/P2) → SENKRON dispose + `locked` (post-frame
  ///   callback idempotent: `_disposeKey` çift-dispose-safe, emit status-guard'lı).
  /// - `locked`/`uninitialized`/`keyAttributesCorrupted` → tutulacak key yok; AMA
  ///   bu state'lerde bir hassas async işlem (unlock/recover/commit/beginSetup)
  ///   DEVAM EDİYOR olabilir → `_abortToBackground = true` ki işlem bitince
  ///   `unlocked`/`setupPending` EMİT ETMESİN (review P1 — complete-after-background).
  ///
  /// **[paused] (Patch 5 — reviewer 2.tur [P1]):** `true` = gerçek arka plan
  /// (`AppLifecycleState.paused`) → HER ZAMAN kesin abort/lock. `false` = `inactive`
  /// (geçici sistem durumu; biyometri/sistem prompt'u da bunu üretir) → eğer
  /// `_biometricPromptInFlight` ise abort ETME (başarılı biyometri unlock'u sistem
  /// prompt'unun ürettiği inactive yüzünden yarıda kesilmesin). Diğer durumlarda
  /// `inactive` de güvenlik-strict davranır (önceki Faz 2 kararı korunur).
  void onAppBackgrounded({required bool paused}) {
    // Biyometri prompt'u devam ederken gelen `inactive` (paused=false) → MUAF.
    // Bu sistem prompt'unun kendisinin ürettiği geçici durum; gerçek arka plan değil.
    if (!paused && _biometricPromptInFlight) return;

    switch (state.status) {
      case VaultLockStatus.unlocked:
        lock(immediate: true); // senkron dispose (review P2)
      case VaultLockStatus.setupPending:
        _abortToBackground = true;
        // Devam eden commit varsa state'i commit sonlandırır (attrs yazıldıysa
        // `locked`); yoksa pending'i temizle → uninitialized (persist YOK).
        if (!_commitInFlight) cancelSetup();
      case VaultLockStatus.locking:
        // İnteraktif lock()'un post-frame dispose'una bel bağlama — paused'ta frame
        // gelmeyebilir (review P1/P2). Hemen senkron dispose + locked.
        _disposeKey();
        emit(_locked());
      case VaultLockStatus.uninitialized:
      case VaultLockStatus.locked:
      case VaultLockStatus.keyAttributesCorrupted:
      case VaultLockStatus.restoring:
      case VaultLockStatus.restoreFailed:
        // Bu state'lerde bellekte masterKey/mnemonic YOK (restore henüz unlock etmedi).
        // Devam eden unlock/recover/beginSetup/biometricUnlock async işlemi varsa
        // unlocked/setupPending'e geçmesini engelle.
        _abortToBackground = true;
    }
  }

  /// Faz 3 Patch 1: Supabase kimlik oturumu kapandı (signOut). Kimlik kapısı
  /// kapanınca E2E kapısı da kapanmalı → hangi vault aşamasında olursa olsun TÜM
  /// volatile state (masterKey/mnemonic) güvenle temizlenir.
  ///
  /// **`lock()` TEK BAŞINA YETMEZ** (`lock` yalnız `unlocked`'ta çalışır; `setupPending`'de
  /// no-op) → bu metot `onAppBackgrounded`'ın durum-bazlı temizlik kalıbını BİREBİR
  /// yansıtır (commit-in-flight kuralı dahil — reviewer [P1]).
  void onAuthSignedOut() {
    switch (state.status) {
      case VaultLockStatus.unlocked:
        lock(immediate: true); // senkron dispose + locked
      case VaultLockStatus.setupPending:
        _abortToBackground = true;
        // Devam eden commit varsa state'i commit sonlandırır (attrs yazıldıysa
        // `locked`); yoksa pending'i temizle → uninitialized (reviewer [P1] :400 kuralı).
        if (!_commitInFlight) cancelSetup();
      case VaultLockStatus.locking:
        // post-frame dispose'a bel bağlama → hemen senkron dispose + locked.
        _disposeKey();
        emit(_locked());
      case VaultLockStatus.uninitialized:
      case VaultLockStatus.locked:
      case VaultLockStatus.keyAttributesCorrupted:
      case VaultLockStatus.restoring:
      case VaultLockStatus.restoreFailed:
        // Bu state'lerde bellekte masterKey/mnemonic YOK. Devam eden unlock/recover/
        // beginSetup/biometricUnlock async işlemi varsa unlocked/setupPending'e geçmesini engelle.
        _abortToBackground = true;
    }
  }

  // --- Reset (integrity / keyAttributesCorrupted son çare) ---

  /// Tüm vault verisini siler (çift onaylı UI aksiyonu sonrası çağrılır).
  /// [VaultStorageKeys.all] → setup'a döner. plaintext + marker dahil silinir →
  /// reset sonrası eski plaintext yeniden migrate EDİLMEZ (yarım durum kalmaz).
  Future<void> resetVault() async {
    _disposeKey();
    _pendingAttrs = null;

    // Security review finding 1 — discard the SERVER token rows too (signed-in
    // only). Otherwise stale ciphertext encrypted under the OLD masterKey lingers
    // and, once sync runs after a fresh setup, can't be decrypted → the user
    // falls into an integrity-error/reset loop. Tombstone (soft-delete) rather
    // than hard-delete: the schema has no DELETE grant and soft-delete is the
    // sync model, so this also propagates the deletion to other devices on pull.
    // The server's key_attributes row is overwritten by the next commitSetup
    // (update-if-exists), not here. Best-effort: the local wipe below ALWAYS
    // completes so the device is clean even offline; the server reconciles later.
    //
    // If the tombstone FAILS (offline/RLS), record the reset instant so the next
    // signed-in unlock retries — otherwise the old rows stay live and re-surface
    // as a corruption banner once a fresh vault syncs (review finding 1, round 2).
    final uid = _uid;
    if (uid != null && _remoteTokenRepo != null) {
      final resetAt = DateTime.now().toUtc().toIso8601String();
      try {
        await _remoteTokenRepo.tombstoneAllRemote(uid);
        await _resetPendingStore?.clear(); // succeeded → no retry owed
      } catch (_) {
        // Couldn't reach the server → owe a retry from the reset instant.
        try {
          await _resetPendingStore?.setPending(resetAt);
        } catch (_) {/* marker write best-effort; local reset still proceeds */}
      }
    }

    // Biyometrik OS anahtarı ayrı options'lı/namespace'li storage'da → `_deleteKeys`
    // (default storage) ona ulaşamayabilir. Doğru options ile sil (reviewer [P1]).
    // disable() idempotent; hata yutulur (reset her durumda tamamlanmalı).
    try {
      await _biometric.disable();
    } catch (_) {/* reset best-effort: biyometri silinemese de devam */}
    _biometricEnrolled = false;
    await _deleteKeys(VaultStorageKeys.all);
    emit(const VaultLockState.uninitialized());
  }

  /// Retries a reset's owed remote tombstone (review finding 1, round 2). If a
  /// reset couldn't reach the server, the marker holds the reset instant; here we
  /// tombstone only rows older than it (a fresh vault's newer tokens are kept).
  /// Best-effort + idempotent; runs before sync's first push so the cut-off is
  /// honoured. Clears the marker on success.
  Future<void> _replayResetTombstoneIfNeeded() async {
    final store = _resetPendingStore;
    final repo = _remoteTokenRepo;
    final uid = _uid;
    if (store == null || repo == null || uid == null) return;
    try {
      final since = await store.pendingSince();
      if (since == null) return;
      await repo.tombstoneAllRemoteBefore(uid, since);
      await store.clear();
    } catch (_) {/* stays pending → retried on a later unlock */}
  }

  // --- Biyometri (Patch 5) ---

  /// Biyometriyi etkinleştir (unlocked-only): masterKey'i taze biometricKey ile
  /// sarmala → OS keystore'a yaz → attrs'a bmk ekle. **Atomik (reviewer 2.tur [P2]):**
  /// OS key yazıldı ama attrs.write FAIL ederse → `biometric.disable()` ile orphan
  /// OS anahtarını temizle + rethrow (state DEĞİŞMEZ). Sıra: önce OS key, sonra attrs.
  Future<void> enableBiometric() async {
    final key = _masterKey;
    if (state.status != VaultLockStatus.unlocked || key == null) {
      throw StateError('enableBiometric: unlocked değil');
    }
    if (!await _biometric.isAvailable()) {
      throw const BiometricUnavailable();
    }
    final attrs = await _readAttrsOrThrow();
    final enroll = _keyManager.enrollBiometric(attrs, key);
    try {
      await _biometric.enroll(enroll.biometricKeyBytes); // 1) OS key
      try {
        await _attrsStore.write(enroll.attrs); // 2) attrs (bmk)
      } catch (_) {
        // attrs yazılamadı → orphan OS key'i temizle, state değişmeden rethrow.
        try {
          await _biometric.disable();
        } catch (_) {/* temizlik best-effort */}
        rethrow;
      }
    } finally {
      enroll.biometricKeyBytes
          .fillRange(0, enroll.biometricKeyBytes.length, 0); // zero-fill
    }
    _biometricEnrolled = true;
    _deviceBiometricAvailable = true;
    emit(_unlocked()); // Settings switch yansısın
  }

  /// Biyometriyi kapat (unlocked-only): OS anahtarını sil → attrs'tan bmk temizle.
  /// **Sıra/hata (reviewer 2.tur [P3]):** `disable()` fail ederse attrs clear'e GEÇME
  /// (state aynı kalır, kullanıcıya hata göster — orphan attrs.bmk + canlı OS key
  /// tutarlı). availability'den BAĞIMSIZ çalışır (lockout'ta bile kapatılabilir).
  Future<void> disableBiometric() async {
    if (state.status != VaultLockStatus.unlocked) {
      throw StateError('disableBiometric: unlocked değil');
    }
    await _biometric.disable(); // fail ederse aşağı geçilmez (rethrow)
    final attrs = await _readAttrsOrThrow();
    await _attrsStore.write(attrs.copyWith(clearBiometric: true));
    _biometricEnrolled = false;
    emit(_unlocked());
  }

  /// Biyometri ile aç (locked-only). **`unlock()` ile birebir aynı ownership +
  /// `_abortToBackground` guard + `_migrate` sırası.** Gerçek geçit
  /// `biometric.retrieve()` (OS prompt). `_biometricPromptInFlight` prompt boyunca
  /// true → sistem prompt'unun ürettiği `inactive` abort'tan muaf (reviewer 2.tur [P1]).
  Future<void> biometricUnlock() async {
    _abortToBackground = false; // hassas işlem başı
    final attrs = await _readAttrsOrThrow();
    await _refreshBiometricState(attrs);

    Uint8List? bytes;
    _biometricPromptInFlight = true;
    try {
      bytes = await _biometric.retrieve(); // OS biyometri prompt + gated read
    } on BiometricCanceled {
      _biometricPromptInFlight = false;
      emit(_locked()); // sessizce parolaya düş
      return;
    } on BiometricLockout {
      _biometricPromptInFlight = false;
      emit(_locked(error: VaultLockError.biometricLockout));
      return;
    } on BiometricKeyMissing {
      _biometricPromptInFlight = false;
      // Enrollment kaybolmuş (biyometri seti değişti vb.) → bmk'yı PERSIST temizle
      // ki sonraki bootstrap tekrar enrolled görüp bozuk-bmk döngüsüne girmesin
      // (reviewer 3.tur [P2]). Write FAIL ederse: disk hâlâ bmk'lı ama UI'da kapalı
      // göster (deviceAvail=false + biometricFailed) → döngü yok; parolayla açıp
      // Settings'ten tekrar dener, sonraki başarılı disable/bootstrap temizler.
      try {
        await _attrsStore.write(attrs.copyWith(clearBiometric: true));
        _biometricEnrolled = false;
        emit(_locked());
      } catch (_) {
        _biometricEnrolled = true;
        _deviceBiometricAvailable = false;
        emit(_locked(error: VaultLockError.biometricFailed));
      }
      return;
    } on BiometricUnavailable {
      _biometricPromptInFlight = false;
      _deviceBiometricAvailable = false;
      emit(_locked());
      return;
    } on BiometricStorageError {
      _biometricPromptInFlight = false;
      emit(_locked(error: VaultLockError.biometricFailed));
      return;
    }
    _biometricPromptInFlight = false;

    // Prompt bittikten sonra arka-plan yarışı: paused olduysa unlocked'a GEÇME.
    if (_abortToBackground) {
      _abortToBackground = false;
      bytes.fillRange(0, bytes.length, 0);
      emit(_locked());
      return;
    }

    final KeyHandle key;
    try {
      key = _keyManager.biometricUnlock(attrs, bytes);
    } on BiometricUnwrapException {
      bytes.fillRange(0, bytes.length, 0);
      emit(_locked(error: VaultLockError.biometricFailed));
      return;
    } finally {
      bytes.fillRange(0, bytes.length, 0); // zero-fill (idempotent)
    }

    var owned = false;
    try {
      await _migrate(key);
      if (_abortToBackground) {
        _abortToBackground = false;
        emit(_locked());
        return;
      }
      _masterKey = key;
      owned = true;
      emit(_unlocked());
      // Patch 3 (Adım K): biyometrik unlock'ta da dirty changePassword'ı yeniden dene.
      unawaited(_backfillRemote());
      unawaited(_replayDirtyAttrsIfNeeded());
    } finally {
      if (!owned) key.dispose();
    }
  }

  /// keyAttributesCorrupted ekranından "Yeniden dene" (geçici okuma hatası ihtimali).
  Future<void> retryBootstrap() => bootstrap();

  Future<KeyAttributes> _readAttrsOrThrow() async {
    final attrs = await _attrsStore.read();
    if (attrs == null) {
      throw StateError('unlock/recover: key attributes yok');
    }
    return attrs;
  }

  void _disposeKey() {
    _masterKey?.dispose(); // idempotent
    _masterKey = null;
  }

  @override
  Future<void> close() {
    _disposeKey();
    _pendingAttrs = null;
    return super.close();
  }
}
