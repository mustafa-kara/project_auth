/// Faz 3 Patch 4 Adım C testleri — FeatureFlag JSON + FeatureFlagsCacheStore +
/// FeatureFlagsService (isEnabled memory-only, ensureLoaded, refresh-fail, listenable). Ağ GEREKMEZ.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:project_auth/features/account/data/feature_flags_cache_store.dart';
import 'package:project_auth/features/account/domain/feature_flags_repository.dart';
import 'package:project_auth/features/account/domain/feature_flags_service.dart';
import 'package:project_auth/features/account/domain/sync_exceptions.dart';

class _FakeStorage implements FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async => data[key];
  @override
  Future<void> write({required String key, required String? value, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async {
    if (value == null) { data.remove(key); } else { data[key] = value; }
  }
  @override
  Future<void> delete({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async => data.remove(key);
  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeFlagsRepo implements FeatureFlagsRepository {
  List<FeatureFlag> flags = const [];
  bool throwError = false;
  int fetchCount = 0;
  @override
  Future<List<FeatureFlag>> fetchAll() async {
    fetchCount++;
    if (throwError) throw const SyncNetworkError();
    return flags;
  }
}

void main() {
  group('FeatureFlag.fromJson', () {
    test('geçerli + payload', () {
      final f = FeatureFlag.fromJson({'key': 'x', 'enabled': true, 'payload': {'p': 1}});
      expect(f.key, 'x');
      expect(f.enabled, isTrue);
      expect(f.payload, {'p': 1});
    });
    test('enabled yanlış tip → FormatException', () {
      expect(() => FeatureFlag.fromJson({'key': 'x', 'enabled': 'yes'}),
          throwsFormatException);
    });
  });

  group('FeatureFlagsCacheStore', () {
    test('write → read round-trip (key→enabled)', () async {
      final store = FeatureFlagsCacheStore(storage: _FakeStorage());
      await store.write({'token_sync_enabled': false, 'other': true});
      expect(await store.read(), {'token_sync_enabled': false, 'other': true});
    });
    test('boş → null', () async {
      expect(await FeatureFlagsCacheStore(storage: _FakeStorage()).read(), isNull);
    });
  });

  group('FeatureFlagsService', () {
    late _FakeFlagsRepo repo;
    late FeatureFlagsCacheStore cache;
    late _FakeStorage storage;

    setUp(() {
      repo = _FakeFlagsRepo();
      storage = _FakeStorage();
      cache = FeatureFlagsCacheStore(storage: storage);
    });

    test('isEnabled bellek boşken fallback döner', () {
      final svc = FeatureFlagsService(repo: repo, cache: cache);
      expect(svc.isEnabled('token_sync_enabled', fallback: true), isTrue);
      expect(svc.isEnabled('token_sync_enabled', fallback: false), isFalse);
    });

    test('refresh → bellek hit (sunucu değeri)', () async {
      repo.flags = [const FeatureFlag(key: 'token_sync_enabled', enabled: false)];
      final svc = FeatureFlagsService(repo: repo, cache: cache);
      await svc.refresh();
      expect(svc.isEnabled('token_sync_enabled', fallback: true), isFalse);
    });

    test('sunucuda yok → fallback', () async {
      repo.flags = [const FeatureFlag(key: 'other', enabled: true)];
      final svc = FeatureFlagsService(repo: repo, cache: cache);
      await svc.refresh();
      expect(svc.isEnabled('token_sync_enabled', fallback: true), isTrue);
    });

    test('refresh ağ hatası → eski cache/bellek korunur', () async {
      repo.flags = [const FeatureFlag(key: 'token_sync_enabled', enabled: false)];
      final svc = FeatureFlagsService(repo: repo, cache: cache);
      await svc.refresh(); // bellek: false
      repo.throwError = true;
      await svc.refresh(); // hata → değişmez
      expect(svc.isEnabled('token_sync_enabled', fallback: true), isFalse);
    });

    test('ensureLoaded: cache hit → fetch YOK + isEnabled cache değeri', () async {
      await cache.write({'token_sync_enabled': false});
      final svc = FeatureFlagsService(repo: repo, cache: cache);
      await svc.ensureLoaded();
      expect(repo.fetchCount, 0, reason: 'cache hit → ağa gitmez');
      expect(svc.isEnabled('token_sync_enabled', fallback: true), isFalse);
    });

    test('ensureLoaded: cache boş + sunucu false → isEnabled false (kill-switch)', () async {
      repo.flags = [const FeatureFlag(key: 'token_sync_enabled', enabled: false)];
      final svc = FeatureFlagsService(repo: repo, cache: cache);
      await svc.ensureLoaded();
      expect(svc.isEnabled('token_sync_enabled', fallback: true), isFalse);
    });

    test('ensureLoaded: cache boş + ağ hatası → fallback=true (sync açık)', () async {
      repo.throwError = true;
      final svc = FeatureFlagsService(repo: repo, cache: cache);
      await svc.ensureLoaded(timeout: const Duration(milliseconds: 50));
      expect(svc.isEnabled('token_sync_enabled', fallback: true), isTrue);
    });

    test('listenable: flag değişince notify (refresh)', () async {
      repo.flags = [const FeatureFlag(key: 'token_sync_enabled', enabled: true)];
      final svc = FeatureFlagsService(repo: repo, cache: cache);
      var notifications = 0;
      svc.listenable.addListener(() => notifications++);
      await svc.refresh(); // true
      repo.flags = [const FeatureFlag(key: 'token_sync_enabled', enabled: false)];
      await svc.refresh(); // false → değişti → notify
      expect(notifications, greaterThanOrEqualTo(1));
      expect(svc.isEnabled('token_sync_enabled', fallback: true), isFalse);
    });
  });
}
