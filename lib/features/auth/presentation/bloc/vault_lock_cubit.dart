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

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/crypto/crypto_exceptions.dart';
import '../../../../core/crypto/key_attributes.dart';
import '../../../../core/crypto/key_handle.dart';
import '../../../auth/domain/key_manager.dart';
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

  static const all = [
    encryptedVault,
    keyAttributes,
    plaintextVault,
    migrationMarker,
    viewMode,
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

  /// Reset / view-mode için storage anahtarlarını silen kanca (DI'dan; testte sahte).
  final Future<void> Function(List<String> keys) _deleteKeys;

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

  VaultLockCubit({
    required KeyManager keyManager,
    required KeyAttributesStore attrsStore,
    required MigrationRunner migrate,
    required Future<void> Function(List<String> keys) deleteKeys,
  })  : _keyManager = keyManager,
        _attrsStore = attrsStore,
        _migrate = migrate,
        _deleteKeys = deleteKeys,
        super(const VaultLockState.uninitialized());

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
      if (attrs == null) {
        emit(const VaultLockState.uninitialized());
      } else {
        emit(const VaultLockState.locked());
      }
    } on FormatException {
      emit(const VaultLockState.keyAttributesCorrupted());
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
      // 2) attrs DİSKE YAZILDI: vault GERÇEKTEN var. Bundan sonra hata olsa bile
      //    setupPending/uninitialized'a GERİ DÖNME → `locked` (vault kurulu; migration
      //    commit-marker'lı/idempotent → sonraki unlock yeniden dener). Hata rethrow.
      try {
        await _migrate(key); // migration VaultCubit.load()'dan ÖNCE bitmeli
      } catch (_) {
        _disposeKey();
        _pendingAttrs = null;
        emit(const VaultLockState.locked());
        rethrow;
      }
      _pendingAttrs = null;
      // commitSetup'ta key zaten _masterKey'in sahibi (setupPending'den). Arka-plan
      // yarışı: işlem sürerken background olduysa unlocked'a GEÇME. attrs DİSKE
      // YAZILDI (write tamamlandı) → vault var → doğru arka-plan state'i `locked`.
      if (_abortToBackground) {
        _abortToBackground = false;
        _disposeKey();
        emit(const VaultLockState.locked());
        return;
      }
      emit(const VaultLockState.unlocked());
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
    final KeyHandle key;
    try {
      key = await _keyManager.unlock(attrs, password);
    } on WrongPasswordException {
      emit(const VaultLockState.locked(error: VaultLockError.wrongPassword));
      return;
    }
    var owned = false;
    try {
      await _migrate(key); // crash sonrası yarım migration unlock yolunda tamamlanır
      // Arka-plan yarışı (review P1): Argon2/migration sürerken app background
      // olduysa key'i sahiplenme + unlocked emit ETME → arka planda kilitli kal.
      if (_abortToBackground) {
        _abortToBackground = false;
        emit(const VaultLockState.locked());
        return; // finally key'i dispose eder (owned=false)
      }
      _masterKey = key;
      owned = true;
      emit(const VaultLockState.unlocked());
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
      // Migration BAŞARIYLA bitmeden sahiplenme (review P1): _migrate fırlatırsa
      // key finally'de dispose edilir, _masterKey null kalır (locked invariant'ı korunur).
      await _migrate(key);
      // Arka-plan yarışı (review P1): işlem sürerken app background olduysa
      // unlocked'a GEÇME → arka planda kilitli kal (key finally'de dispose).
      if (_abortToBackground) {
        _abortToBackground = false;
        emit(const VaultLockState.locked());
        return;
      }
      _masterKey = key;
      owned = true;
      emit(const VaultLockState.unlocked());
    } on WrongRecoveryKeyException {
      emit(const VaultLockState.locked(error: VaultLockError.wrongRecovery));
    } on WeakPasswordException {
      emit(const VaultLockState.locked(error: VaultLockError.weakPassword));
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
      emit(const VaultLockState.locked());
      return;
    }
    // İnteraktif: subtree teardown router redirect ile başlar; sonraki frame'de dispose.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isClosed) return;
      // Frame gelmeden background olduysa onAppBackgrounded zaten senkron dispose
      // edip `locked`'a geçmiştir (review P1/P2) → bu stale callback no-op.
      if (state.status != VaultLockStatus.locking) return;
      _disposeKey();
      emit(const VaultLockState.locked());
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
  void onAppBackgrounded() {
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
        emit(const VaultLockState.locked());
      case VaultLockStatus.uninitialized:
      case VaultLockStatus.locked:
      case VaultLockStatus.keyAttributesCorrupted:
        // Devam eden unlock/recover/beginSetup async işlemi varsa unlocked/
        // setupPending'e geçmesini engelle.
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
    await _deleteKeys(VaultStorageKeys.all);
    emit(const VaultLockState.uninitialized());
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
