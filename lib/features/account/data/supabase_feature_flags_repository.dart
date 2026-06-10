/// [FeatureFlagsRepository]'nin Supabase (PostgREST) implementasyonu (Faz 3 Patch 4).
///
/// `feature_flags` public read tablosu. Yalnız SELECT. Sunucu şeması DEĞİŞMEZ.
/// Bozuk satır karantina (atla — UI bozulmaz).
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/feature_flags_repository.dart';
import '../domain/sync_exceptions.dart';

class SupabaseFeatureFlagsRepository implements FeatureFlagsRepository {
  SupabaseFeatureFlagsRepository(this._client);

  final SupabaseClient _client;

  static const String _table = 'feature_flags';

  @override
  Future<List<FeatureFlag>> fetchAll() async {
    try {
      final rows = await _client.from(_table).select('key,enabled,payload');
      final out = <FeatureFlag>[];
      for (final row in rows) {
        try {
          out.add(FeatureFlag.fromJson(row));
        } on FormatException {
          // bozuk satır karantina: atla.
        }
      }
      return out;
    } catch (e) {
      throw _mapError(e);
    }
  }

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
