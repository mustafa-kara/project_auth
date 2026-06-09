/// [KeyAttributesRepository]'nin Supabase (PostgREST) implementasyonu (Faz 3 Patch 2).
///
/// Sunucu şeması DEĞİŞMEZ: mevcut `key_attributes` tablosu (bytea kolonlar). Lokal
/// `EncryptedBlob` nonce+ciphertext'i BİRLİKTE tutar; sunucu AYRI kolonlar → [_toRow]
/// böler, [_fromRow] birleştirir. bytea<->byte dönüşümü [ByteaCodec] (tek nokta).
///
/// **`bmk` ve blob `version` GÖNDERİLMEZ** (sunucuda kolon yok). `bmk` cihaz-yerel
/// (yeni cihaz biyometriyi yeniden enroll eder — Patch 1 ile tutarlı). Restore'da blob
/// `version = EncryptedBlob.supportedVersion` (=1) ile kurulur.
library;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/crypto/encrypted_blob.dart';
import '../../../core/crypto/key_attributes.dart';
import '../domain/key_attributes_repository.dart';
import '../domain/sync_exceptions.dart';
import 'bytea_codec.dart';

class SupabaseKeyAttributesRepository implements KeyAttributesRepository {
  SupabaseKeyAttributesRepository(this._client);

  final SupabaseClient _client;

  static const String _table = 'key_attributes';

  @override
  Future<KeyAttributes?> fetch(String uid) async {
    try {
      final row = await _client
          .from(_table)
          .select()
          .eq('user_id', uid)
          .maybeSingle();
      if (row == null) return null; // gerçek 0-row → setup (ağ hatası DEĞİL)
      return fromRow(row);
    } on FormatException {
      // bytea decode / EncryptedBlob / KeyAttributes validasyonu başarısız.
      throw const SyncMalformedRemote();
    } catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<bool> existsRemote(String uid) async {
    try {
      final row = await _client
          .from(_table)
          .select('user_id')
          .eq('user_id', uid)
          .maybeSingle();
      return row != null;
    } catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<void> upload(String uid, KeyAttributes attrs) async {
    try {
      await _client.from(_table).insert(toRow(uid, attrs));
    } catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<void> update(String uid, KeyAttributes attrs) async {
    try {
      // updated_at GÖNDERİLMEZ (toRow'da yok → trigger now() ezer; LWW).
      await _client.from(_table).update(toRow(uid, attrs)).eq('user_id', uid);
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// KeyAttributes → sunucu satırı. `EncryptedBlob` İKİ kolona BÖLÜNÜR.
  /// `bmk`/blob-version GÖNDERİLMEZ (sunucuda kolon yok). Yalnız zaten-şifreli
  /// alanlar + KDF parametreleri — masterKey/KEK/secret ASLA yer almaz.
  @visibleForTesting
  static Map<String, dynamic> toRow(String uid, KeyAttributes attrs) => {
        'user_id': uid,
        'kdf_salt': ByteaCodec.encode(attrs.kdfSalt),
        'kdf_ops': attrs.kdfOps,
        'kdf_mem': attrs.kdfMem,
        'encrypted_master_key':
            ByteaCodec.encode(attrs.encryptedMasterKey.ciphertext),
        'master_key_nonce': ByteaCodec.encode(attrs.encryptedMasterKey.nonce),
        'recovery_encrypted_master_key':
            ByteaCodec.encode(attrs.recoveryEncryptedMasterKey.ciphertext),
        'recovery_nonce':
            ByteaCodec.encode(attrs.recoveryEncryptedMasterKey.nonce),
      };

  /// Sunucu satırı → KeyAttributes. İki bytea kolon → bir `EncryptedBlob` MERGE.
  /// `bmk` YOK → null. Eksik kolon / geçersiz bytea → [FormatException] (fetch
  /// bunu [SyncMalformedRemote]'a çevirir). Throws [FormatException] on bad data.
  @visibleForTesting
  static KeyAttributes fromRow(Map<String, dynamic> row) {
    final salt = ByteaCodec.decode(_str(row, 'kdf_salt'));
    final emkCipher = ByteaCodec.decode(_str(row, 'encrypted_master_key'));
    final emkNonce = ByteaCodec.decode(_str(row, 'master_key_nonce'));
    final remkCipher =
        ByteaCodec.decode(_str(row, 'recovery_encrypted_master_key'));
    final remkNonce = ByteaCodec.decode(_str(row, 'recovery_nonce'));
    return KeyAttributes(
      kdfSalt: salt,
      kdfOps: _int(row, 'kdf_ops'),
      kdfMem: _int(row, 'kdf_mem'),
      encryptedMasterKey:
          EncryptedBlob(nonce: emkNonce, ciphertext: emkCipher),
      recoveryEncryptedMasterKey:
          EncryptedBlob(nonce: remkNonce, ciphertext: remkCipher),
      // bmk sunucuda yok → null (yeni cihaz biyometriyi yeniden enroll eder).
    );
  }

  static String _str(Map<String, dynamic> row, String key) {
    final v = row[key];
    if (v is String) return v;
    throw FormatException('key_attributes."$key" String bekleniyordu (${v.runtimeType})');
  }

  static int _int(Map<String, dynamic> row, String key) {
    final v = row[key];
    if (v is int) return v;
    throw FormatException('key_attributes."$key" int bekleniyordu (${v.runtimeType})');
  }

  /// PostgREST/ağ hatasını domain [SyncError]'a eşler.
  SyncError _mapError(Object e) {
    if (e is SyncError) return e;
    if (e is AuthRetryableFetchException) return const SyncNetworkError();
    if (e is PostgrestException) {
      final code = e.code ?? '';
      // RLS/yetki: PostgREST 401/403 veya "42501" (insufficient_privilege).
      if (code == '42501' || code == 'PGRST301' || code == '401' || code == '403') {
        return const SyncPermissionDenied();
      }
      return SyncUnknownError('PostgREST ${e.code ?? ''}: ${e.message}');
    }
    // Socket/timeout/diğer ağ istisnaları.
    return const SyncNetworkError();
  }
}
