/// Faz 3 Patch 4 Adım B testleri — CatalogService JSON round-trip + CatalogCacheStore
/// + IssuerCatalog.canonicalIssuer (slug tutarlılığı, eşleşme/no-op dalları). Ağ GEREKMEZ.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:project_auth/features/vault/data/catalog_cache_store.dart';
import 'package:project_auth/features/vault/domain/catalog_repository.dart';
import 'package:project_auth/features/vault/domain/issuer_catalog.dart';

class _FakeStorage implements FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async => data[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async => data.remove(key);
  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

CatalogService _svc(String name, {String? issuer, String? logo}) =>
    CatalogService(id: 'id-$name', name: name, issuer: issuer, logoUrl: logo);

void main() {
  group('CatalogService JSON', () {
    test('round-trip kayıpsız', () {
      final s = _svc(
        'GitHub',
        issuer: 'github.com',
        logo: 'https://x/logo.svg',
      );
      final back = CatalogService.fromJson(s.toJson());
      expect(back.id, s.id);
      expect(back.name, 'GitHub');
      expect(back.issuer, 'github.com');
      expect(back.logoUrl, 'https://x/logo.svg');
    });

    test('issuer/logo null tolere', () {
      final back = CatalogService.fromJson({'id': 'i', 'name': 'X'});
      expect(back.issuer, isNull);
      expect(back.logoUrl, isNull);
    });

    test('name eksik → FormatException', () {
      expect(() => CatalogService.fromJson({'id': 'i'}), throwsFormatException);
    });
  });

  group('CatalogCacheStore', () {
    test('write → read round-trip', () async {
      final store = CatalogCacheStore(storage: _FakeStorage());
      await store.write([_svc('GitHub', issuer: 'github'), _svc('Google')]);
      final read = await store.read();
      expect(read, isNotNull);
      expect(read!.map((s) => s.name), ['GitHub', 'Google']);
    });

    test('boş cache → null', () async {
      final store = CatalogCacheStore(storage: _FakeStorage());
      expect(await store.read(), isNull);
    });

    test('bozuk JSON → null (yok say)', () async {
      final storage = _FakeStorage();
      storage.data[CatalogCacheStore.storageKey] = '{not json';
      final store = CatalogCacheStore(storage: storage);
      expect(await store.read(), isNull);
    });
  });

  group('IssuerCatalog.canonicalIssuer', () {
    // Katalog issuer'ı 'github' (simple-icons slug ile aynı normalizasyon).
    final catalog = IssuerCatalog([
      _svc('GitHub', issuer: 'github'),
      _svc('Google'),
    ]);

    test('eşleşen issuer → kanonik ad', () {
      expect(catalog.canonicalIssuer('github'), 'GitHub');
    });

    test(
      'slug normalizasyonu: GitHub / github / GITHUB / git-hub hepsi → GitHub',
      () {
        expect(catalog.canonicalIssuer('GitHub'), 'GitHub');
        expect(catalog.canonicalIssuer('github'), 'GitHub');
        expect(catalog.canonicalIssuer('GITHUB'), 'GitHub');
        expect(
          catalog.canonicalIssuer('git-hub'),
          'GitHub',
          reason: 'slug alfanümerik dışını temizler',
        );
      },
    );

    test('issuer yoksa name slug ile eşleşir (Google)', () {
      expect(catalog.canonicalIssuer('google'), 'Google');
    });

    test('eşleşme yok → null (değiştirme)', () {
      expect(catalog.canonicalIssuer('mybank'), isNull);
    });

    test('null/boş raw → null', () {
      expect(catalog.canonicalIssuer(null), isNull);
      expect(catalog.canonicalIssuer('   '), isNull);
    });

    test('empty katalog → daima null (no-op)', () {
      expect(IssuerCatalog.empty().canonicalIssuer('github'), isNull);
    });
  });
}
