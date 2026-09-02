/// Feature flags lokal cache (Faz 3 Patch 4) — `feature_flags_cache_v1`.
///
/// **GLOBAL** (keyPrefix YOK) — PUBLIC veri, kullanıcıdan bağımsız. Offline fallback:
/// yalnız `key→enabled` map'i tutulur (payload v1'de cache'lenmez). vault reset'inde SİLİNMEZ.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class FeatureFlagsCacheStore {
  static const storageKey = 'feature_flags_cache_v1';

  final FlutterSecureStorage _storage;

  FeatureFlagsCacheStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  Future<Map<String, bool>?> read() async {
    final raw = await _storage.read(key: storageKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final out = <String, bool>{};
      decoded.forEach((k, v) {
        if (k is String && v is bool) out[k] = v;
      });
      return out;
    } catch (_) {
      return null; // bozuk cache → yok say
    }
  }

  Future<void> write(Map<String, bool> flags) =>
      _storage.write(key: storageKey, value: jsonEncode(flags));

  Future<void> clear() => _storage.delete(key: storageKey);
}
