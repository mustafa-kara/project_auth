/// Issuer kanonikleştirme (Faz 3 Patch 4) — saf, deterministik.
///
/// QR/manuel parse SONRASI issuer'ı katalogdaki **kanonik ad**a hizalar (örn. `github.com`
/// → `GitHub`). Eşleşme yoksa null (DEĞİŞTİRME). **`IssuerAvatar.slugFor` YENİDEN KULLANILIR**
/// → avatar eşleşmesi ile katalog eşleşmesi AYNI slug normalizasyonunu kullanır (divergence yok).
///
/// `logo_url` KULLANILMAZ (yok-sayılır; gizlilik kararı korunur — runtime ağ resmi yok).
library;

import '../../../core/ui/widgets/issuer_avatar.dart';
import 'catalog_repository.dart';

class IssuerCatalog {
  IssuerCatalog(List<CatalogService> services)
      : _bySlug = _index(services);

  /// Boş katalog (henüz yüklenmedi/offline) — `canonicalIssuer` daima null döner (no-op).
  IssuerCatalog.empty() : _bySlug = const {};

  final Map<String, String> _bySlug; // slug → kanonik ad

  /// Katalog boş mu (henüz yüklenmedi) — holder cache-ısıtma kararı için.
  bool get isEmptyCatalog => _bySlug.isEmpty;

  static Map<String, String> _index(List<CatalogService> services) {
    final map = <String, String>{};
    for (final s in services) {
      // Eşleşme anahtarı: issuer (yoksa name) slug'ı. Değer: kanonik name.
      final key = IssuerAvatar.slugFor(s.issuer ?? s.name);
      if (key.isEmpty) continue;
      map.putIfAbsent(key, () => s.name);
    }
    return map;
  }

  /// Raw issuer'ı kanonik ada hizalar; eşleşme yoksa null (çağıran DEĞİŞTİRMEZ).
  String? canonicalIssuer(String? rawIssuer) {
    final raw = (rawIssuer ?? '').trim();
    if (raw.isEmpty) return null;
    final slug = IssuerAvatar.slugFor(raw);
    if (slug.isEmpty) return null;
    return _bySlug[slug];
  }
}
