/// Faz 3 Patch 4 Adım A testleri — StableDeviceIdStore + DeviceRepository.parseRow
/// + DeviceRegistrar (onSignedIn/onResumed register-fallback). Gerçek ağ GEREKMEZ.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:project_auth/features/account/data/stable_device_id_store.dart';
import 'package:project_auth/features/account/data/supabase_device_repository.dart';
import 'package:project_auth/features/account/domain/device_registrar.dart';
import 'package:project_auth/features/account/domain/device_repository.dart';
import 'package:project_auth/features/account/domain/sync_exceptions.dart';
import 'package:uuid/uuid.dart';

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

/// Sabit id üreten Uuid (test determinizmi).
class _FixedUuid extends Uuid {
  _FixedUuid(this.value);
  final String value;
  @override
  String v4({dynamic config, Map<String, dynamic>? options}) => value;
}

class _FakeDeviceRepo implements DeviceRepository {
  int registerCount = 0;
  String? lastRegisteredId;
  int touchCount = 0;
  int touchReturns = 1; // etkilenen satır
  bool throwOnRegister = false;
  bool throwOnTouch = false;

  @override
  Future<void> register(
    String uid, {
    required String deviceId,
    String? name,
  }) async {
    registerCount++;
    lastRegisteredId = deviceId;
    if (throwOnRegister) throw const SyncNetworkError();
  }

  @override
  Future<int> touchLastSeen(String uid, String deviceId) async {
    touchCount++;
    if (throwOnTouch) throw const SyncNetworkError();
    return touchReturns;
  }

  @override
  Future<List<DeviceRow>> list(String uid) async => const [];
}

void main() {
  group('StableDeviceIdStore', () {
    test('getOrCreate ilk çağrıda üretir+yazar, ikincide AYNI id', () async {
      final store = StableDeviceIdStore(
        storage: _FakeStorage(),
        uuid: _FixedUuid('dev-uuid-1'),
      );
      final a = await store.getOrCreate();
      final b = await store.getOrCreate();
      expect(a, 'dev-uuid-1');
      expect(b, 'dev-uuid-1', reason: 'idempotent: aynı id döner');
      expect(await store.read(), 'dev-uuid-1');
    });

    test('read henüz üretilmemişse null', () async {
      final store = StableDeviceIdStore(storage: _FakeStorage());
      expect(await store.read(), isNull);
    });
  });

  group('SupabaseDeviceRepository.parseRow', () {
    test('geçerli satır → DeviceRow (timestamptz UTC)', () {
      final row = SupabaseDeviceRepository.parseRow({
        'device_id': 'd1',
        'name': 'Pixel',
        'last_seen': '2026-06-10T10:00:00Z',
        'created_at': '2026-06-09T08:00:00Z',
      });
      expect(row.deviceId, 'd1');
      expect(row.name, 'Pixel');
      expect(row.lastSeen, DateTime.utc(2026, 6, 10, 10));
      expect(row.createdAt, DateTime.utc(2026, 6, 9, 8));
    });

    test('name null + last_seen null tolere edilir', () {
      final row = SupabaseDeviceRepository.parseRow({
        'device_id': 'd1',
        'name': null,
        'last_seen': null,
        'created_at': '2026-06-09T08:00:00Z',
      });
      expect(row.name, isNull);
      expect(row.lastSeen, isNull);
    });

    test('device_id eksik → FormatException', () {
      expect(
        () => SupabaseDeviceRepository.parseRow({
          'created_at': '2026-06-09T08:00:00Z',
        }),
        throwsFormatException,
      );
    });

    test('created_at parse edilemez → FormatException', () {
      expect(
        () => SupabaseDeviceRepository.parseRow({
          'device_id': 'd1',
          'created_at': 'not-a-date',
        }),
        throwsFormatException,
      );
    });
  });

  group('DeviceRegistrar', () {
    late _FakeDeviceRepo repo;
    late StableDeviceIdStore idStore;
    late _FakeStorage storage;

    setUp(() {
      repo = _FakeDeviceRepo();
      storage = _FakeStorage();
      idStore = StableDeviceIdStore(
        storage: storage,
        uuid: _FixedUuid('dev-1'),
      );
    });

    test('onSignedIn → getOrCreate + register', () async {
      final reg = DeviceRegistrar(repo: repo, idStore: idStore);
      await reg.onSignedIn('uid-A');
      expect(repo.registerCount, 1);
      expect(repo.lastRegisteredId, 'dev-1');
      expect(await idStore.read(), 'dev-1');
    });

    test('onSignedIn ağ hatası best-effort yutulur (throw etmez)', () async {
      repo.throwOnRegister = true;
      final reg = DeviceRegistrar(repo: repo, idStore: idStore);
      await reg.onSignedIn('uid-A'); // throw ETMEMELİ
      expect(repo.registerCount, 1);
    });

    test('onResumed: id yoksa no-op', () async {
      final reg = DeviceRegistrar(repo: repo, idStore: idStore);
      await reg.onResumed('uid-A');
      expect(repo.touchCount, 0);
      expect(repo.registerCount, 0);
    });

    test('onResumed: touchLastSeen ≥1 satır → register ÇAĞRILMAZ', () async {
      await idStore.getOrCreate();
      repo.touchReturns = 1;
      final reg = DeviceRegistrar(repo: repo, idStore: idStore);
      await reg.onResumed('uid-A');
      expect(repo.touchCount, 1);
      expect(repo.registerCount, 0, reason: 'row var → fallback yok');
    });

    test(
      'onResumed: touchLastSeen 0 satır → register FALLBACK (review [P2]#3)',
      () async {
        await idStore.getOrCreate();
        repo.touchReturns = 0; // sunucuda row yok (ilk register düşmüş)
        final reg = DeviceRegistrar(repo: repo, idStore: idStore);
        await reg.onResumed('uid-A');
        expect(repo.touchCount, 1);
        expect(
          repo.registerCount,
          1,
          reason: '0 satır → register row oluşturur',
        );
        expect(repo.lastRegisteredId, 'dev-1');
      },
    );

    test('onResumed ağ hatası best-effort yutulur', () async {
      await idStore.getOrCreate();
      repo.throwOnTouch = true;
      final reg = DeviceRegistrar(repo: repo, idStore: idStore);
      await reg.onResumed('uid-A'); // throw ETMEMELİ
      expect(repo.touchCount, 1);
    });
  });
}
