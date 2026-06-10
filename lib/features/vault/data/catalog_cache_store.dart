/// Katalog lokal cache deposu (Faz 3 Patch 4) — `catalog_services_cache_v1`.
///
/// **GLOBAL** (keyPrefix YOK) — katalog PUBLIC veri, kullanıcıdan bağımsız. Offline/
/// ilk-açılış fallback: ağ yoksa son cache kullanılır (cache yoksa boş → kanonikleştirme
/// no-op). vault reset'inde SİLİNMEZ (uid-bağımsız; public veri, gizlilik sorunu yok).
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/catalog_repository.dart';

class CatalogCacheStore {
  static const storageKey = 'catalog_services_cache_v1';

  final FlutterSecureStorage _storage;

  CatalogCacheStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  Future<List<CatalogService>?> read() async {
    final raw = await _storage.read(key: storageKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final out = <CatalogService>[];
      for (final e in decoded) {
        if (e is Map<String, dynamic>) {
          try {
            out.add(CatalogService.fromJson(e));
          } on FormatException {
            // bozuk cache girdisi atlanır
          }
        }
      }
      return out;
    } catch (_) {
      return null; // bozuk cache → yok say
    }
  }

  Future<void> write(List<CatalogService> services) {
    final encoded = jsonEncode(services.map((s) => s.toJson()).toList());
    return _storage.write(key: storageKey, value: encoded);
  }

  Future<void> clear() => _storage.delete(key: storageKey);
}
