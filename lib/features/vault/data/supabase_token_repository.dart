/// [RemoteTokenRepository]'nin Supabase (PostgREST + Realtime) implementasyonu (Faz 3 Patch 3).
///
/// Sunucu şeması DEĞİŞMEZ: mevcut `tokens` tablosu (bytea ciphertext+nonce). Lokal
/// `EncryptedBlob` nonce+ciphertext'i BİRLİKTE tutar; sunucu AYRI kolonlar → [_toRow]
/// böler, pull AYRI kolonları birleştirir. bytea<->byte dönüşümü [ByteaCodec] (tek nokta).
/// Patch 2 `SupabaseKeyAttributesRepository` kalıbını yansıtır (hata map → [SyncError]).
///
/// **Realtime yalnız TETİKLEYİCİ:** supabase-flutter Realtime bytea'yı çift-encode eder
/// (#1180) → payload OKUNMAZ; değişiklik sinyali REST `pullSince` tetikler.
/// **Açık secret/masterKey ASLA gönderilmez** — yalnız opak ciphertext/nonce.
library;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/crypto/encrypted_blob.dart';
import '../../account/data/bytea_codec.dart';
import '../../account/domain/sync_exceptions.dart';
import '../domain/raw_token_record.dart';
import '../domain/remote_token_repository.dart';

class SupabaseTokenRepository implements RemoteTokenRepository {
  SupabaseTokenRepository(this._client);

  final SupabaseClient _client;

  static const String _table = 'tokens';

  @override
  Future<RemotePullResult> pullSince(String uid, String? sinceIso) async {
    try {
      final base = _client
          .from(_table)
          .select('id,ciphertext,nonce,version,updated_at,deleted')
          .eq('user_id', uid);
      // sinceIso null → full pull; aksi halde `updated_at > sinceIso`.
      final filtered = sinceIso == null
          ? base
          : base.gt('updated_at', sinceIso);
      final List<dynamic> rows = await filtered.order('updated_at');

      final out = <RemoteTokenRow>[];
      var malformed = 0;
      String?
      safeCursor; // İLK malformed'dan ÖNCEki son valid updated_at (cap).
      var sawMalformed = false;

      for (final raw in rows) {
        final row = _asMap(raw);
        final parsed = tryParseRow(row);
        if (parsed == null) {
          // Bozuk satır: ATLA + say. Cursor bundan SONRASINI kapsayamaz (gap).
          malformed++;
          sawMalformed = true;
          continue;
        }
        out.add(parsed);
        // Cursor cap'i: yalnız İLK malformed'dan ÖNCEki valid'lere kadar ilerler.
        if (!sawMalformed) safeCursor = parsed.serverUpdatedAtIso;
      }

      return RemotePullResult(
        rows: out,
        malformedCount: malformed,
        safeCursorIso: safeCursor,
      );
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// Tek `upsert` isteğinde gönderilen EN FAZLA satır sayısı (review takibi).
  /// Büyük bir import/ilk-senkron tek gövdede binlerce bytea satırı yollardı →
  /// PostgREST/gateway gövde limiti (413) ya da statement timeout. Parçalar
  /// SIRAYLA gönderilir; upsert id-bazlı idempotent olduğu için yarıda kalan bir
  /// push bir sonraki denemede kaldığı yerden tamamlanır.
  @visibleForTesting
  static const int upsertChunkSize = 500;

  /// [records]'ı [upsertChunkSize]'lık ardışık parçalara böler (sıra korunur).
  @visibleForTesting
  static List<List<RawTokenRecord>> chunkRecords(List<RawTokenRecord> records) {
    final out = <List<RawTokenRecord>>[];
    for (var i = 0; i < records.length; i += upsertChunkSize) {
      final end = (i + upsertChunkSize < records.length)
          ? i + upsertChunkSize
          : records.length;
      out.add(records.sublist(i, end));
    }
    return out;
  }

  @override
  Future<void> pushUpsert(String uid, List<RawTokenRecord> records) async {
    if (records.isEmpty) return;
    try {
      for (final chunk in chunkRecords(records)) {
        final rows = [for (final r in chunk) toRow(uid, r)];
        // id-bazlı idempotent: PK çakışmada UPDATE. updated_at/created_at GÖNDERİLMEZ.
        await _client.from(_table).upsert(rows, onConflict: 'id');
      }
    } catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<void> tombstoneAllRemote(String uid) async {
    try {
      // Soft-delete every row (the schema has no hard DELETE grant — soft-delete
      // is the sync model). updated_at is omitted so the trigger bumps it → other
      // devices pull the tombstones via LWW. RLS scopes to user_id = auth.uid();
      // the explicit eq is a defensive filter.
      await _client.from(_table).update({'deleted': true}).eq('user_id', uid);
    } catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<void> tombstoneAllRemoteBefore(String uid, String beforeIso) async {
    try {
      await _client
          .from(_table)
          .update({'deleted': true})
          .eq('user_id', uid)
          .lt('updated_at', beforeIso);
    } catch (e) {
      throw _mapError(e);
    }
  }

  @override
  RealtimeChannelHandle subscribe(String uid, void Function() onChange) {
    // Kullanıcıya özel kanal; yalnız kendi satır olayları (RLS + filter).
    final channel = _client
        .channel('tokens:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: _table,
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: uid,
          ),
          // Payload OKUNMAZ (#1180 bytea çift-encode) — yalnız tetikleyici.
          callback: (_) => onChange(),
        )
        .subscribe();
    return _SupabaseChannelHandle(_client, channel);
  }

  /// RawTokenRecord → sunucu satırı. `EncryptedBlob` İKİ kolona BÖLÜNÜR. `updated_at`/
  /// `created_at` GÖNDERİLMEZ (trigger ezer). Yalnız opak ciphertext/nonce + version + deleted.
  @visibleForTesting
  static Map<String, dynamic> toRow(String uid, RawTokenRecord r) => {
    'id': r.id,
    'user_id': uid,
    'ciphertext': ByteaCodec.encode(r.blob.ciphertext),
    'nonce': ByteaCodec.encode(r.blob.nonce),
    'version': r.version,
    'deleted': r.deleted,
  };

  /// Sunucu satırı → RemoteTokenRow. Bozuk (bytea/nonce/eksik kolon/tarih) → null
  /// (çağıran karantina sayar). İki bytea kolon → bir `EncryptedBlob` MERGE.
  @visibleForTesting
  static RemoteTokenRow? tryParseRow(Map<String, dynamic> row) {
    try {
      final id = row['id'];
      if (id is! String) return null;
      final cipher = ByteaCodec.decode(_str(row, 'ciphertext'));
      final nonce = ByteaCodec.decode(_str(row, 'nonce'));
      final blob = EncryptedBlob(nonce: nonce, ciphertext: cipher);
      final version = row['version'] is int ? row['version'] as int : 1;
      final deleted = row['deleted'] == true;
      final updatedAt = DateTime.parse(_str(row, 'updated_at')).toUtc();
      return RemoteTokenRow(
        id: id,
        blob: blob,
        version: version,
        serverUpdatedAt: updatedAt,
        deleted: deleted,
      );
    } catch (_) {
      // FormatException (bytea/blob/tarih) / tip hatası → karantina.
      return null;
    }
  }

  static Map<String, dynamic> _asMap(dynamic row) {
    if (row is Map<String, dynamic>) return row;
    if (row is Map) {
      return {for (final e in row.entries) e.key.toString(): e.value};
    }
    throw const FormatException('tokens satırı Map değil');
  }

  static String _str(Map<String, dynamic> row, String key) {
    final v = row[key];
    if (v is String) return v;
    throw FormatException(
      'tokens."$key" String bekleniyordu (${v.runtimeType})',
    );
  }

  /// PostgREST/ağ hatasını domain [SyncError]'a eşler (Patch 2 kalıbı).
  SyncError _mapError(Object e) {
    if (e is SyncError) return e;
    if (e is AuthRetryableFetchException) return const SyncNetworkError();
    if (e is PostgrestException) {
      final code = e.code ?? '';
      if (code == '42501' ||
          code == 'PGRST301' ||
          code == '401' ||
          code == '403') {
        return const SyncPermissionDenied();
      }
      return SyncUnknownError('PostgREST ${e.code ?? ''}: ${e.message}');
    }
    return const SyncNetworkError();
  }
}

class _SupabaseChannelHandle implements RealtimeChannelHandle {
  _SupabaseChannelHandle(this._client, this._channel);

  final SupabaseClient _client;
  final RealtimeChannel _channel;

  @override
  Future<void> unsubscribe() async {
    await _client.removeChannel(_channel);
  }
}
