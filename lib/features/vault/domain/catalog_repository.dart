/// TOTP servis kataloğu sunucu deposu — soyutlama (Faz 3 Patch 4).
///
/// `catalog_services` tablosu (public read; anon+authenticated SELECT). Yalnız OKUNUR
/// (client yazma grant'ı YOK). Sunucu şeması DEĞİŞMEZ. E2E'ye DOKUNMAZ (secret taşımaz).
///
/// **`logoUrl` taşınır AMA YOK SAYILIR** (kullanıcı kararı + gizlilik): mevcut `IssuerAvatar`
/// "runtime logo çekme YOK (offline/gizlilik)" kararı korunur; katalog yalnız issuer AD/slug
/// kanonikleştirmesi için kullanılır (bkz. IssuerCatalog). `logoUrl` ileri-uyum için tutulur.
library;

import '../../account/domain/sync_exceptions.dart';

class CatalogService {
  final String id;
  final String name;
  final String? issuer;
  final String? logoUrl;

  const CatalogService({
    required this.id,
    required this.name,
    required this.issuer,
    required this.logoUrl,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (issuer != null) 'issuer': issuer,
    if (logoUrl != null) 'logo_url': logoUrl,
  };

  /// Cache JSON → model. Throws [FormatException] on bad data.
  static CatalogService fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String) {
      throw FormatException(
        'catalog_services.id String bekleniyordu (${id.runtimeType})',
      );
    }
    if (name is! String) {
      throw FormatException(
        'catalog_services.name String bekleniyordu (${name.runtimeType})',
      );
    }
    final issuer = json['issuer'];
    final logo = json['logo_url'];
    return CatalogService(
      id: id,
      name: name,
      issuer: issuer is String ? issuer : null,
      logoUrl: logo is String ? logo : null,
    );
  }
}

abstract interface class CatalogRepository {
  /// Tüm katalog servislerini çeker (public read). Ağ/izin hatası → [SyncError].
  Future<List<CatalogService>> fetchAll();
}
