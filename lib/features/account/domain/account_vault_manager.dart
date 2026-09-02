/// Multi-vault yönetimi: uid ↔ lokal vault namespace + legacy (Faz 2 uid-siz) vault
/// bağlama/migration (Faz 3 Patch 1, kullanıcı kararı 7 + reviewer [P1]/[P2]/[P3]).
///
/// **Sorumluluklar:**
/// - uid için storage namespace prefix'i üret (`'<uid>/'`).
/// - `linkRequired(uid)` hesapla (signedIn UI guard'ı için senkron hydrate edilir):
///   legacy uid-siz vault VAR + bu uid için legacy kararı YOK.
/// - "İlişkilendir": legacy anahtarları uid namespace'ine taşı (KAYIPSIZ) + `bmk`
///   TEMİZLE (`clearBiometric` + `biometric.disable()`) → legacy tüketilir.
/// - "Yeni boş vault": legacy'ye dokunma, yalnız bu uid'i "kararlı" işaretle.
///
/// ⚠️ Biyometri: OS-keystore anahtarı SABİT namespace'te (`vault_biometric`) → uid
/// taşımada `bmk` taşınamaz; temizlenir + disable → kullanıcı yeniden enroll eder
/// (parola+recovery her zaman çalışır, kayıp yok).
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../auth/data/key_attributes_store.dart';
import '../../auth/domain/biometric_service.dart';
import '../../vault/data/encrypted_vault_repository.dart';
import '../../vault/data/vault_migration.dart';
import '../../vault/data/view_mode_store.dart';
import '../data/active_account_store.dart';
import '../data/legacy_link_store.dart';

class AccountVaultManager {
  AccountVaultManager({
    required FlutterSecureStorage storage,
    required ActiveAccountStore activeStore,
    required LegacyLinkStore legacyStore,
    required BiometricService biometric,
  }) : _storage = storage,
       _active = activeStore,
       _legacy = legacyStore,
       _biometric = biometric;

  final FlutterSecureStorage _storage;
  final ActiveAccountStore _active;
  final LegacyLinkStore _legacy;
  final BiometricService _biometric;

  /// uid → storage namespace prefix. Boş uid asla kullanılmaz (signedIn şart).
  static String prefixFor(String uid) => '$uid/';

  /// Cihazda uid-siz (Faz 2) vault VAR mı? = uid-siz `key_attributes` anahtarı dolu.
  Future<bool> legacyVaultExists() async {
    final raw = await _storage.read(key: KeyAttributesStore.storageKey);
    return raw != null && raw.isNotEmpty;
  }

  /// signedIn UI guard'ı için: bu uid `/auth/link` ekranına gitmeli mi?
  /// = legacy vault var && bu uid için karar verilmemiş.
  Future<bool> linkRequired(String uid) async {
    if (await _legacy.isDecided(uid)) return false;
    return legacyVaultExists();
  }

  /// "İlişkilendir": legacy uid-siz anahtarları uid namespace'ine taşı + `bmk`
  /// temizle + biyometriyi disable et + aktif uid + karar marker.
  ///
  /// Sıra (kayıpsızlık): yeni anahtarları yaz → eski uid-siz anahtarları sil →
  /// marker'ları yaz. Crash olursa eski anahtarlar durur (sonraki açılış tekrar dener).
  Future<void> linkLegacyToUser(String uid) async {
    final prefix = prefixFor(uid);

    // 1) key_attributes: uid-siz oku → `bmk` TEMİZLE → uid namespace'e yaz.
    final legacyAttrsStore = KeyAttributesStore(storage: _storage);
    final attrs = await legacyAttrsStore
        .read(); // FormatException → çağıran ele alır
    if (attrs != null) {
      final cleared = attrs.copyWith(clearBiometric: true); // bmk taşınmaz
      await KeyAttributesStore(
        storage: _storage,
        keyPrefix: prefix,
      ).write(cleared);
    }

    // 2) encrypted vault: uid-siz JSON'u uid namespace'e kopyala (ciphertext aynen).
    final legacyVault = await _storage.read(
      key: EncryptedVaultRepository.vaultKey,
    );
    if (legacyVault != null && legacyVault.isNotEmpty) {
      await _storage.write(
        key: '$prefix${EncryptedVaultRepository.vaultKey}',
        value: legacyVault,
      );
    }

    // 3) view mode + migration marker.
    final legacyView = await _storage.read(key: ViewModeStore.storageKey);
    if (legacyView != null) {
      await _storage.write(
        key: '$prefix${ViewModeStore.storageKey}',
        value: legacyView,
      );
    }
    final legacyMarker = await _storage.read(key: VaultMigration.markerKey);
    if (legacyMarker != null) {
      await _storage.write(
        key: '$prefix${VaultMigration.markerKey}',
        value: legacyMarker,
      );
    }

    // 4) Biyometri OS anahtarını temizle (sabit namespace'te kaldığı için taşınamaz;
    //    bmk zaten attrs'tan düşürüldü → tutarlı). best-effort.
    try {
      await _biometric.disable();
    } catch (_) {
      /* yeniden enroll gerekir; engel değil */
    }

    // 5) Eski uid-siz anahtarları sil (taşındı). plaintext Faz1 zaten yok/taşınmış.
    await _storage.delete(key: KeyAttributesStore.storageKey);
    await _storage.delete(key: EncryptedVaultRepository.vaultKey);
    await _storage.delete(key: ViewModeStore.storageKey);
    await _storage.delete(key: VaultMigration.markerKey);

    // 6) Aktif uid + karar marker → legacy tüketildi, linkRequired düşer.
    await _active.write(uid);
    await _legacy.markDecided(uid);
  }

  /// "Yeni boş vault": legacy uid-siz vault'a DOKUNMA (başka hesaba teklif edilebilir
  /// kalır) → yalnız bu uid'i kararlı işaretle + aktif uid.
  Future<void> startFreshVault(String uid) async {
    await _active.write(uid);
    await _legacy.markDecided(uid);
  }

  /// Hesap aktif kılındığında (legacy kararı GEREKMEYEN normal akış): aktif uid'i yaz.
  Future<void> setActive(String uid) => _active.write(uid);

  Future<String?> activeUid() => _active.read();
}
