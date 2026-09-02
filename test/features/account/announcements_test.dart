/// Faz 3 Patch 4 Adım D testleri — Announcement JSON + cache round-trip +
/// visibleAnnouncements audience filtre. Ağ GEREKMEZ.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:project_auth/features/account/data/announcements_cache_store.dart';
import 'package:project_auth/features/account/domain/announcements_repository.dart';

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

Announcement _ann(String id, String audience) => Announcement(
  id: id,
  title: 'T-$id',
  body: 'B-$id',
  audience: audience,
  createdAt: DateTime.utc(2026, 6, 10),
);

void main() {
  group('Announcement.fromJson', () {
    test('geçerli satır', () {
      final a = Announcement.fromJson({
        'id': 'a1',
        'title': 'Hi',
        'body': 'Body',
        'audience': 'ios',
        'created_at': '2026-06-10T00:00:00Z',
      });
      expect(a.id, 'a1');
      expect(a.audience, 'ios');
      expect(a.createdAt, DateTime.utc(2026, 6, 10));
    });
    test('audience eksik → all (default)', () {
      final a = Announcement.fromJson({
        'id': 'a1',
        'title': 'Hi',
        'body': 'B',
        'created_at': '2026-06-10T00:00:00Z',
      });
      expect(a.audience, 'all');
    });
    test('created_at parse edilemez → FormatException', () {
      expect(
        () => Announcement.fromJson({
          'id': 'a1',
          'title': 'Hi',
          'body': 'B',
          'created_at': 'x',
        }),
        throwsFormatException,
      );
    });
  });

  group('AnnouncementsCacheStore', () {
    test('write → read round-trip', () async {
      final store = AnnouncementsCacheStore(storage: _FakeStorage());
      await store.write([_ann('1', 'all'), _ann('2', 'ios')]);
      final read = await store.read();
      expect(read!.map((a) => a.id), ['1', '2']);
      expect(read[1].audience, 'ios');
    });
    test('boş → null', () async {
      expect(
        await AnnouncementsCacheStore(storage: _FakeStorage()).read(),
        isNull,
      );
    });
  });

  group('visibleAnnouncements (audience filtre)', () {
    final all = [
      _ann('all', 'all'),
      _ann('flutter', 'flutter'),
      _ann('android', 'android'),
      _ann('ios', 'ios'),
    ];

    test(
      'android platformunda: all + flutter + android görünür, ios gizli',
      () {
        final vis = visibleAnnouncements(all, platformOverride: 'android');
        expect(
          vis.map((a) => a.id),
          containsAll(['all', 'flutter', 'android']),
        );
        expect(vis.map((a) => a.id), isNot(contains('ios')));
      },
    );

    test('ios platformunda: all + flutter + ios görünür, android gizli', () {
      final vis = visibleAnnouncements(all, platformOverride: 'ios');
      expect(vis.map((a) => a.id), containsAll(['all', 'flutter', 'ios']));
      expect(vis.map((a) => a.id), isNot(contains('android')));
    });

    test('all daima görünür', () {
      final vis = visibleAnnouncements([
        _ann('x', 'all'),
      ], platformOverride: 'unknown');
      expect(vis.length, 1);
    });
  });
}
