/// [AnnouncementsRepository]'nin Supabase (PostgREST) implementasyonu (Faz 3 Patch 4).
///
/// `announcements` public read tablosu. Yalnız SELECT (en yeni önce). Sunucu şeması
/// DEĞİŞMEZ. Bozuk satır karantina (atla). audience client-side filtrelenir (repo değil).
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/announcements_repository.dart';
import '../domain/sync_exceptions.dart';

class SupabaseAnnouncementsRepository implements AnnouncementsRepository {
  SupabaseAnnouncementsRepository(this._client);

  final SupabaseClient _client;

  static const String _table = 'announcements';

  @override
  Future<List<Announcement>> fetchAll() async {
    try {
      final rows = await _client
          .from(_table)
          .select('id,title,body,audience,created_at')
          .order('created_at', ascending: false);
      final out = <Announcement>[];
      for (final row in rows) {
        try {
          out.add(Announcement.fromJson(row));
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
