/// IssuerCatalog tutucu (Faz 3 Patch 4) — refresh'te yeniden kurulan mutable katalog.
///
/// signedIn/unlock'ta `refresh()` ile sunucudan çekilir (cache.write + holder rebuild).
/// VaultCubit `current`'i okur (resolver). Best-effort: ağ hatası → cache'teki/boş kalır.
/// Holder GLOBAL singleton (katalog kullanıcıdan bağımsız PUBLIC veri).
library;

import '../data/catalog_cache_store.dart';
import 'catalog_repository.dart';
import 'issuer_catalog.dart';

class IssuerCatalogHolder {
  IssuerCatalogHolder({required CatalogRepository repo, required CatalogCacheStore cache})
      : _repo = repo,
        _cache = cache;

  final CatalogRepository _repo;
  final CatalogCacheStore _cache;

  IssuerCatalog _current = IssuerCatalog.empty();

  /// Güncel katalog (VaultCubit resolver bunu okur). Boş başlar → kanonikleştirme no-op.
  IssuerCatalog get current => _current;

  /// Cache'i belleğe ısıt + ağdan yenile (best-effort). Hata → mevcut korunur.
  Future<void> refresh() async {
    // 1) Cache (offline/ilk-açılış).
    if (_current.isEmptyCatalog) {
      final cached = await _cache.read();
      if (cached != null && cached.isNotEmpty) _current = IssuerCatalog(cached);
    }
    // 2) Ağ.
    try {
      final fresh = await _repo.fetchAll();
      await _cache.write(fresh);
      _current = IssuerCatalog(fresh);
    } catch (_) {
      // best-effort: cache/boş kalır.
    }
  }
}
