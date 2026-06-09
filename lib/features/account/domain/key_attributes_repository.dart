/// Kripto metadatasının (`key_attributes`) sunucu deposu — soyutlama (Faz 3 Patch 2).
///
/// **Yalnız zaten-şifreli metadata** taşınır: KDF parametreleri (`salt/ops/mem`) +
/// `encryptedMasterKey`/`recoveryEncryptedMasterKey` (masterKey'in KEK/recovery-key ile
/// sarmalı hâli) + nonce'lar. **masterKey, KEK, recovery key, açık TOTP secret ASLA**
/// sunucuya gitmez. `bmk` (biyometri wrap) da gitmez (cihaz-yerel; sunucu şemasında kolon yok).
///
/// Sunucu şeması DEĞİŞMEZ (mevcut `key_attributes` tablosu; bytea kolonlar). Lokal
/// `EncryptedBlob` nonce+ciphertext'i BİRLİKTE tutar; sunucu AYRI kolonlar → impl böler/birleştirir.
library;

import '../../../core/crypto/key_attributes.dart';

abstract interface class KeyAttributesRepository {
  /// uid'in sunucudaki kripto metadatasını çeker.
  ///
  /// - Kayıt yoksa (gerçek 0-row) → `null` (setup yolu).
  /// - Ağ/RLS/format hatası → [SyncError] FIRLATIR (restore'da `restoreFailed`'a gider,
  ///   ASLA 0-row gibi ele alınmaz → çift-vault önlenir).
  Future<KeyAttributes?> fetch(String uid);

  /// Sunucuda bu uid için kayıt VAR mı (upload guard'ı). Ağ hatası → [SyncError].
  Future<bool> existsRemote(String uid);

  /// İlk backfill: kripto metadatasını sunucuya YAZAR (insert).
  ///
  /// Çağıran ÖNCE [existsRemote] ile guard'lar (server-wins: var olanı EZME).
  /// Ağ/izin hatası → [SyncError].
  Future<void> upload(String uid, KeyAttributes attrs);

  /// Mevcut satırı GÜNCELLER (Faz 3 Patch 3 — changePassword/recovery-new-password
  /// sonrası sunucudaki sarmal yenilenir; LWW `updated_at` trigger ile). masterKey
  /// DEĞİŞMEZ (yalnız KEK-sarmalı döner) → token re-encrypt gerekmez. Ağ/izin → [SyncError].
  Future<void> update(String uid, KeyAttributes attrs);
}
