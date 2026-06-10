/// [CatalogRepository]'nin Supabase (PostgREST) implementasyonu (Faz 3 Patch 4).
///
/// `catalog_services` public read tablosu. Yalnız SELECT. Sunucu şeması DEĞİŞMEZ.
/// Bozuk satır KARANTİNA edilir (atla — Patch 3 felsefesi; UI bozulmaz). `logo_url`
/// parse edilir ama kullanılmaz (yok-sayılır; ileri-uyum).
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../account/domain/sync_exceptions.dart';
import '../domain/catalog_repository.dart';

class SupabaseCatalogRepository implements CatalogRepository {
  SupabaseCatalogRepository(this._client);

  final SupabaseClient _client;

  static const String _table = 'catalog_services';

  @override
  Future<List<CatalogService>> fetchAll() async {
    try {
      final rows = await _client.from(_table).select('id,name,issuer,logo_url');
      final out = <CatalogService>[];
      for (final row in rows) {
        try {
          out.add(CatalogService.fromJson(row));
        } on FormatException {
          // Bozuk satır karantina: atla (sağlam satırlar yine döner).
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
