/// Merkezi feature-flag tüketicisi (Faz 3 Patch 4) — cache + offline fallback + listenable.
///
/// **`token_sync_enabled` kill-switch:** flag AÇIKÇA `enabled=false` ise token sync durur.
/// Flag yok/bilinmiyor/offline → `fallback=true` (sync ÇALIŞIR; yalnız sunucu açık `false`
/// derse kapanır). `key_attributes` yolları flag-DIŞI (kimlik kurtarma her zaman çalışır).
///
/// **`isEnabled` YALNIZ bellek snapshot'ı okur** (senkron API async secure-storage cache'ini
/// DOĞRUDAN okuyamaz). Cache'i belleğe yüklemek `bootstrap`/`ensureLoaded` SORUMLULUĞU.
///
/// **`listenable` (`ValueListenable<int>`):** `refresh` flag map'ini değiştirince notify eder
/// → TokenSyncService self-subscribe ile gate'i yeniden değerlendirir (Realtime bypass'ı kapatır).
library;

import 'package:flutter/foundation.dart';

import '../data/feature_flags_cache_store.dart';
import 'feature_flags_repository.dart';

class FeatureFlagsService {
  FeatureFlagsService({
    required FeatureFlagsRepository repo,
    required FeatureFlagsCacheStore cache,
  }) : _repo = repo,
       _cache = cache;

  final FeatureFlagsRepository _repo;
  final FeatureFlagsCacheStore _cache;

  /// Bellek snapshot'ı (key→enabled). null = henüz yüklenmedi → `isEnabled` fallback'e düşer.
  Map<String, bool>? _memory;

  /// Flag değişince artan sürüm sayacı; abone (TokenSyncService) bunu dinler.
  final ValueNotifier<int> _version = ValueNotifier<int>(0);
  ValueListenable<int> get listenable => _version;

  /// YALNIZ bellek snapshot'ı okur (senkron; async I/O YOK). Bellekte key yoksa [fallback].
  bool isEnabled(String key, {required bool fallback}) {
    final mem = _memory;
    if (mem == null) return fallback;
    return mem[key] ?? fallback;
  }

  /// Belleği hazırlar (cache-ready GARANTİSİ — `start` öncesi await edilir). Bellek doluysa
  /// anında döner; boşsa cache'i ısıt; cache de boşsa bounded `refresh` denemesi (timeout).
  /// Sonunda bellek ya gerçek değer ya boş (→ `isEnabled` fallback). Karar `isEnabled` ile okunur.
  Future<void> ensureLoaded({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (_memory != null) return;
    final cached = await _cache.read();
    if (cached != null) {
      _setMemory(cached, notify: false);
      return;
    }
    try {
      await refresh().timeout(timeout);
    } catch (_) {
      // timeout/ağ → bellek boş kalır → isEnabled fallback (token sync: fallback=true).
    }
  }

  /// Sunucudan çeker → cache.write + bellek güncelle + (değiştiyse) notify. Best-effort
  /// (ağ hatası → eski cache/bellek korunur).
  Future<void> refresh() async {
    try {
      final flags = await _repo.fetchAll();
      final map = {for (final f in flags) f.key: f.enabled};
      await _cache.write(map);
      _setMemory(map, notify: true);
    } catch (_) {
      // best-effort: bellek/cache değişmez (offline'da eski değer kalır).
    }
  }

  void _setMemory(Map<String, bool> map, {required bool notify}) {
    final changed = !mapEquals(_memory, map);
    _memory = map;
    if (notify && changed) _version.value++;
  }

  void dispose() => _version.dispose();
}
