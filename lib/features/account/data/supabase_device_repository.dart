/// [DeviceRepository]'nin Supabase (PostgREST) implementasyonu (Faz 3 Patch 4).
///
/// `devices` tablosu (owner-only RLS; composite PK `(user_id, device_id)`; trigger YOK).
/// Sunucu şeması DEĞİŞMEZ. Sunucuya yalnız opak `device_id` + opsiyonel `name`/`last_seen`
/// gider — donanım tanımlayıcı/IP/konum ASLA. `created_at` GÖNDERİLMEZ (DEFAULT now()).
/// `last_seen` client ISO yazar (trigger yok → server ezmez).
library;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/device_repository.dart';
import '../domain/sync_exceptions.dart';

class SupabaseDeviceRepository implements DeviceRepository {
  SupabaseDeviceRepository(this._client, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final SupabaseClient _client;
  final DateTime Function() _now;

  static const String _table = 'devices';

  String _nowIso() => _now().toUtc().toIso8601String();

  @override
  Future<void> register(String uid,
      {required String deviceId, String? name}) async {
    try {
      final row = <String, dynamic>{
        'user_id': uid,
        'device_id': deviceId,
        'last_seen': _nowIso(),
        // created_at GÖNDERİLMEZ (DEFAULT now()).
      };
      if (name != null) row['name'] = name;
      await _client.from(_table).upsert(row, onConflict: 'user_id,device_id');
    } catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<int> touchLastSeen(String uid, String deviceId) async {
    try {
      // .select() → güncellenen satırları DÖNER; uzunluk = etkilenen satır sayısı.
      // 0 → sunucuda row yok (ilk register ağ hatasıyla düşmüş) → registrar fallback.
      final rows = await _client
          .from(_table)
          .update({'last_seen': _nowIso()})
          .eq('user_id', uid)
          .eq('device_id', deviceId)
          .select('device_id');
      return rows.length;
    } catch (e) {
      throw _mapError(e);
    }
  }

  @override
  Future<List<DeviceRow>> list(String uid) async {
    try {
      final rows = await _client
          .from(_table)
          .select('device_id,name,last_seen,created_at')
          .eq('user_id', uid)
          .order('last_seen');
      return rows.map(parseRow).toList(growable: false);
    } on FormatException {
      throw const SyncMalformedRemote();
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// Sunucu satırı → [DeviceRow]. Throws [FormatException] on bad data.
  @visibleForTesting
  static DeviceRow parseRow(Map<String, dynamic> row) {
    final id = row['device_id'];
    if (id is! String) {
      throw FormatException('devices.device_id String bekleniyordu (${id.runtimeType})');
    }
    final createdRaw = row['created_at'];
    if (createdRaw is! String) {
      throw FormatException(
          'devices.created_at String bekleniyordu (${createdRaw.runtimeType})');
    }
    final created = DateTime.tryParse(createdRaw);
    if (created == null) {
      throw FormatException('devices.created_at parse edilemedi: $createdRaw');
    }
    final name = row['name'];
    final lastSeenRaw = row['last_seen'];
    return DeviceRow(
      deviceId: id,
      name: name is String ? name : null,
      lastSeen: lastSeenRaw is String ? DateTime.tryParse(lastSeenRaw)?.toUtc() : null,
      createdAt: created.toUtc(),
    );
  }

  /// PostgREST/ağ hatasını domain [SyncError]'a eşler (Patch 2/3 kalıbı).
  SyncError _mapError(Object e) {
    if (e is SyncError) return e;
    if (e is AuthRetryableFetchException) return const SyncNetworkError();
    if (e is PostgrestException) {
      final code = e.code ?? '';
      if (code == '42501' || code == 'PGRST301' || code == '401' || code == '403') {
        return const SyncPermissionDenied();
      }
      return SyncUnknownError('PostgREST ${e.code ?? ''}: ${e.message}');
    }
    return const SyncNetworkError();
  }
}
