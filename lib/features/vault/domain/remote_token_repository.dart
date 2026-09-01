/// Faz 3 Patch 3 — şifreli token'ların sunucu (Supabase `tokens`) transport portu.
///
/// **Yalnız opak satırlar konuşur:** ciphertext/nonce (`EncryptedBlob`) + version +
/// sunucu `updated_at` + deleted. masterKey/açık secret ASLA. Patch 2
/// `KeyAttributesRepository` kalıbını yansıtır (ByteaCodec + SyncError).
library;

import '../../../core/crypto/encrypted_blob.dart';
import 'raw_token_record.dart';

/// Sunucudan çekilen tek token satırı (opak). `serverUpdatedAt` = LWW hakemi
/// (trigger `now()`); merge bunu kullanır (client epoch-ms DEĞİL).
class RemoteTokenRow {
  final String id;
  final EncryptedBlob blob;
  final int version;

  /// Sunucu `updated_at` (UTC normalize). ISO-8601 string'i `serverUpdatedAtIso`.
  final DateTime serverUpdatedAt;
  final bool deleted;

  RemoteTokenRow({
    required this.id,
    required this.blob,
    required this.version,
    required this.serverUpdatedAt,
    required this.deleted,
  });

  /// Merge + cursor için kanonik ISO-8601 UTC temsili.
  String get serverUpdatedAtIso => serverUpdatedAt.toUtc().toIso8601String();
}

/// `pullSince` sonucu — sağlam satırlar + karantina sayısı + güvenli cursor cap'i.
///
/// **Bozuk-satır karantinası (tek satır TÜM pull'u düşürmesin):** başarılı yanıt
/// içindeki tek malformed satır ATLANIR + sayılır. [safeCursorIso] = İLK malformed
/// satırdan ÖNCEki son valid `updated_at` (yoksa null) → cursor bunu aşamaz (gap
/// atlanmaz; sunucu düzelirse tekrar denenir). Malformed yoksa = tüm sağlamların max'ı.
class RemotePullResult {
  final List<RemoteTokenRow> rows;
  final int malformedCount;
  final String? safeCursorIso;

  const RemotePullResult({
    required this.rows,
    this.malformedCount = 0,
    this.safeCursorIso,
  });
}

/// Realtime abonelik handle'ı — yalnız iptal taşır (test fake'i `onChange`'i elle
/// tetikler; `SupabaseClient` testte hiç kullanılmaz).
abstract interface class RealtimeChannelHandle {
  Future<void> unsubscribe();
}

/// Sunucu token transport portu.
abstract interface class RemoteTokenRepository {
  /// `updated_at > sinceIso` (sinceIso null → full pull). Hata → `SyncError` (throw).
  Future<RemotePullResult> pullSince(String uid, String? sinceIso);

  /// id-bazlı idempotent upsert (`onConflict: 'id'`). `updated_at`/`created_at`
  /// GÖNDERİLMEZ (trigger ezer). Hata → `SyncError`.
  Future<void> pushUpsert(String uid, List<RawTokenRecord> records);

  /// Realtime: yalnız TETİKLEYİCİ (bytea payload #1180 → OKUNMAZ). Değişiklikte
  /// [onChange] çağrılır (çağıran REST pull tetikler).
  RealtimeChannelHandle subscribe(String uid, void Function() onChange);

  /// Soft-deletes (tombstones) ALL of this uid's server token rows on vault reset.
  ///
  /// Sets `deleted = true` for every row via UPDATE (the schema deliberately has
  /// no hard DELETE — soft-delete is the sync model; see the init migration). A
  /// wiped vault must not leave live remote ciphertext that the new masterKey
  /// can't decrypt; tombstoning marks them gone and propagates the deletion to
  /// other devices on their next pull. Idempotent. Network/permission →
  /// `SyncError`; the caller treats it as best-effort.
  Future<void> tombstoneAllRemote(String uid);

  /// Like [tombstoneAllRemote] but only rows with `updated_at < beforeIso`.
  ///
  /// Used to RETRY a reset's tombstone after it failed offline: by the time the
  /// retry runs, a fresh vault may have pushed new tokens for the same uid. The
  /// reset instant cut-off tombstones only the OLD (pre-reset) rows and leaves
  /// the new vault's tokens intact. Idempotent; network/permission → `SyncError`.
  Future<void> tombstoneAllRemoteBefore(String uid, String beforeIso);
}
