/// Duyuru lokal cache (Faz 3 Patch 4) — `announcements_cache_v1`.
///
/// **GLOBAL** (keyPrefix YOK) — PUBLIC veri. Offline fallback. vault reset'inde SİLİNMEZ.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/announcements_repository.dart';

class AnnouncementsCacheStore {
  static const storageKey = 'announcements_cache_v1';

  final FlutterSecureStorage _storage;

  AnnouncementsCacheStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  Future<List<Announcement>?> read() async {
    final raw = await _storage.read(key: storageKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final out = <Announcement>[];
      for (final e in decoded) {
        if (e is Map<String, dynamic>) {
          try {
            out.add(Announcement.fromJson(e));
          } on FormatException {
            // bozuk girdi atlanır
          }
        }
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(List<Announcement> items) => _storage.write(
    key: storageKey,
    value: jsonEncode(items.map((a) => a.toJson()).toList()),
  );

  Future<void> clear() => _storage.delete(key: storageKey);
}
