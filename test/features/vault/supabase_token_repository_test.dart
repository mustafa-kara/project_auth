/// SupabaseTokenRepository mapping + ağ yolu testleri (Faz 3 Patch 3).
///
/// İki katman:
///  1. Saf statik dönüşümler (`toRow`/`tryParseRow`/`chunkRecords`) — RawTokenRecord
///     ↔ sunucu satırı round-trip KAYIPSIZ; bozuk satır → null karantina.
///  2. Ağ yüzeyi: GERÇEK `SupabaseClient` sahte bir HTTP istemcisiyle kurulur
///     (`test/support/fake_http_client.dart`). Böylece PostgREST'in kendi istek
///     üretimi (metot/yol/query/`Prefer`/gövde) ve hata ayrıştırması denetlenir;
///     elle yazılmış bir PostgREST taklidi DEĞİL. Soket dışında her şey gerçek.
///
/// Realtime (`subscribe`) HÂLÂ kapsam dışı: WebSocket taşıması sahte HTTP
/// istemcisinden geçmez → manuel/integration checklist'te kalır.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/features/account/data/bytea_codec.dart';
import 'package:project_auth/features/account/domain/sync_exceptions.dart';
import 'package:project_auth/features/vault/data/supabase_token_repository.dart';
import 'package:project_auth/features/vault/domain/raw_token_record.dart';

import '../../support/fake_http_client.dart';

EncryptedBlob _blob(int seed) => EncryptedBlob(
  nonce: Uint8List.fromList(
    List.generate(EncryptedBlob.nonceBytes, (i) => (i + seed) & 0xff),
  ),
  ciphertext: Uint8List.fromList(
    List.generate(48, (i) => (i * 7 + seed) & 0xff),
  ),
);

RawTokenRecord _rec(String id, {bool deleted = false}) => RawTokenRecord(
  id: id,
  blob: _blob(5),
  updatedAtMs: 1000,
  version: 1,
  deleted: deleted,
);

/// PostgREST'in SELECT'te döndürdüğü satırın birebir şekli (bytea → `\x<hex>`).
Map<String, dynamic> _serverRow(
  String id, {
  required int seed,
  required String updatedAt,
  int version = 1,
  bool deleted = false,
}) {
  final blob = _blob(seed);
  return {
    'id': id,
    'ciphertext': ByteaCodec.encode(blob.ciphertext),
    'nonce': ByteaCodec.encode(blob.nonce),
    'version': version,
    'updated_at': updatedAt,
    'deleted': deleted,
  };
}

void main() {
  group('toRow', () {
    test('6 kolon; updated_at/created_at/user_id-secret GÖNDERİLMEZ', () {
      final row = SupabaseTokenRepository.toRow('uid-A', _rec('t1'));
      expect(
        row.keys,
        containsAll(<String>{
          'id',
          'user_id',
          'ciphertext',
          'nonce',
          'version',
          'deleted',
        }),
      );
      expect(row.containsKey('updated_at'), isFalse);
      expect(row.containsKey('created_at'), isFalse);
      // bytea \x+hex formatı.
      expect(row['ciphertext'], startsWith(r'\x'));
      expect(row['nonce'], startsWith(r'\x'));
    });

    test('deleted bayrağı taşınır (tombstone push)', () {
      final row = SupabaseTokenRepository.toRow(
        'uid-A',
        _rec('t1', deleted: true),
      );
      expect(row['deleted'], isTrue);
    });
  });

  group('pushUpsert chunking', () {
    test('1200 kayıt → 3 parça (500/500/200) = 3 upsert çağrısı', () {
      final records = [for (var i = 0; i < 1200; i++) _rec('t$i')];
      final chunks = SupabaseTokenRepository.chunkRecords(records);
      expect(
        chunks,
        hasLength(3),
        reason: 'pushUpsert her parça için bir upsert gönderir',
      );
      expect(chunks.map((c) => c.length), [500, 500, 200]);
    });

    test('sıra korunur (parçalar birleştirilince orijinal liste)', () {
      final records = [for (var i = 0; i < 1200; i++) _rec('t$i')];
      final flat = [
        for (final c in SupabaseTokenRepository.chunkRecords(records)) ...c,
      ];
      expect(flat.map((r) => r.id), records.map((r) => r.id));
    });

    test('sınır boyu tek parça kalır, +1 ikiye böler', () {
      const size = SupabaseTokenRepository.upsertChunkSize;
      expect(
        SupabaseTokenRepository.chunkRecords([
          for (var i = 0; i < size; i++) _rec('t$i'),
        ]),
        hasLength(1),
      );
      expect(
        SupabaseTokenRepository.chunkRecords([
          for (var i = 0; i < size + 1; i++) _rec('t$i'),
        ]),
        hasLength(2),
      );
    });

    test('boş liste → parça YOK (istek gönderilmez)', () {
      expect(SupabaseTokenRepository.chunkRecords(const []), isEmpty);
    });
  });

  group('tryParseRow', () {
    test('round-trip KAYIPSIZ (toRow → satır → tryParseRow)', () {
      final rec = _rec('t1');
      final row = SupabaseTokenRepository.toRow('uid-A', rec);
      // Sunucu döndürürken updated_at ekler.
      row['updated_at'] = '2026-06-09T10:00:00Z';
      final parsed = SupabaseTokenRepository.tryParseRow(row)!;
      expect(parsed.id, 't1');
      expect(parsed.version, 1);
      expect(parsed.deleted, isFalse);
      expect(parsed.serverUpdatedAtIso, '2026-06-09T10:00:00.000Z');
      // blob birebir.
      expect(parsed.blob.ciphertext, rec.blob.ciphertext);
      expect(parsed.blob.nonce, rec.blob.nonce);
    });

    test('bozuk bytea (geçersiz hex) → null (karantina)', () {
      final parsed = SupabaseTokenRepository.tryParseRow({
        'id': 'bad',
        'ciphertext': r'\xZZZZ', // geçersiz hex
        'nonce': ByteaCodec.encode(Uint8List(24)),
        'version': 1,
        'deleted': false,
        'updated_at': '2026-06-09T10:00:00Z',
      });
      expect(parsed, isNull);
    });

    test('nonce uzunluğu yanlış → null (EncryptedBlob reddi)', () {
      final parsed = SupabaseTokenRepository.tryParseRow({
        'id': 'bad',
        'ciphertext': ByteaCodec.encode(Uint8List(16)),
        'nonce': ByteaCodec.encode(Uint8List(8)), // 24 olmalı
        'version': 1,
        'deleted': false,
        'updated_at': '2026-06-09T10:00:00Z',
      });
      expect(parsed, isNull);
    });

    test('eksik updated_at → null', () {
      final parsed = SupabaseTokenRepository.tryParseRow({
        'id': 'x',
        'ciphertext': ByteaCodec.encode(Uint8List(16)),
        'nonce': ByteaCodec.encode(Uint8List(24)),
        'version': 1,
        'deleted': false,
        // updated_at YOK
      });
      expect(parsed, isNull);
    });

    test('id String değil → null', () {
      final parsed = SupabaseTokenRepository.tryParseRow({
        'id': 123,
        'ciphertext': ByteaCodec.encode(Uint8List(16)),
        'nonce': ByteaCodec.encode(Uint8List(24)),
        'version': 1,
        'deleted': false,
        'updated_at': '2026-06-09T10:00:00Z',
      });
      expect(parsed, isNull);
    });
  });

  group('pushUpsert (gerçek PostgREST isteği, sahte soket)', () {
    test('1200 kayıt → 3 POST (500/500/200); on_conflict=id + '
        'Prefer: resolution=merge-duplicates', () async {
      final http = RecordingHttpClient();
      final client = fakeSupabaseClient(http);
      addTearDown(client.dispose);

      await SupabaseTokenRepository(
        client,
      ).pushUpsert('uid-A', [for (var i = 0; i < 1200; i++) _rec('t$i')]);

      expect(http.requests, hasLength(3));
      expect(
        http.requests.map((r) => (r.json as List).length),
        [500, 500, 200],
        reason: 'chunkRecords parçaları SIRAYLA gönderilir',
      );
      for (final req in http.requests) {
        expect(req.method, 'POST');
        expect(req.path, '/rest/v1/tokens');
        expect(req.query['on_conflict'], 'id');
        expect(req.headers['Prefer'], contains('resolution=merge-duplicates'));
      }
    });

    test(
      'gövdedeki her satır TAM 6 kolon; updated_at/created_at YOK',
      () async {
        final http = RecordingHttpClient();
        final client = fakeSupabaseClient(http);
        addTearDown(client.dispose);

        await SupabaseTokenRepository(
          client,
        ).pushUpsert('uid-A', [_rec('t1'), _rec('t2', deleted: true)]);

        final rows = (http.requests.single.json as List).cast<Map>();
        expect(rows, hasLength(2));
        for (final row in rows) {
          expect(row.keys.toSet(), <String>{
            'id',
            'user_id',
            'ciphertext',
            'nonce',
            'version',
            'deleted',
          });
          expect(row['user_id'], 'uid-A');
          expect(row['ciphertext'] as String, startsWith(r'\x'));
        }
        expect(rows[1]['deleted'], isTrue, reason: 'tombstone push edilir');
      },
    );

    test('boş liste → HİÇ istek gönderilmez', () async {
      final http = RecordingHttpClient();
      final client = fakeSupabaseClient(http);
      addTearDown(client.dispose);

      await SupabaseTokenRepository(client).pushUpsert('uid-A', const []);

      expect(http.requests, isEmpty);
    });

    test(
      '403 + PostgREST hata gövdesi (42501) → SyncPermissionDenied',
      () async {
        final http = RecordingHttpClient(
          (_) => FakeHttpResponse.json(const {
            'code': '42501',
            'message': 'new row violates row-level security policy',
            'details': null,
            'hint': null,
          }, status: 403),
        );
        final client = fakeSupabaseClient(http);
        addTearDown(client.dispose);

        await expectLater(
          SupabaseTokenRepository(client).pushUpsert('uid-A', [_rec('t1')]),
          throwsA(isA<SyncPermissionDenied>()),
        );
      },
    );

    test('401 (JSON olmayan gövde) → SyncPermissionDenied', () async {
      final http = RecordingHttpClient(
        (_) => const FakeHttpResponse(status: 401, body: 'Unauthorized'),
      );
      final client = fakeSupabaseClient(http);
      addTearDown(client.dispose);

      await expectLater(
        SupabaseTokenRepository(client).pushUpsert('uid-A', [_rec('t1')]),
        throwsA(isA<SyncPermissionDenied>()),
      );
    });

    test('500 → SyncUnknownError (kod mesajda taşınır)', () async {
      final http = RecordingHttpClient(
        (_) => const FakeHttpResponse(status: 500, body: 'boom'),
      );
      final client = fakeSupabaseClient(http);
      addTearDown(client.dispose);

      await expectLater(
        SupabaseTokenRepository(client).pushUpsert('uid-A', [_rec('t1')]),
        throwsA(
          isA<SyncUnknownError>().having(
            (e) => e.message,
            'message',
            contains('PostgREST 500'),
          ),
        ),
      );
    });

    test('SocketException (ağ yok) → SyncNetworkError', () async {
      final http = RecordingHttpClient(
        (_) => throw const SocketException('offline'),
      );
      final client = fakeSupabaseClient(http);
      addTearDown(client.dispose);

      await expectLater(
        SupabaseTokenRepository(client).pushUpsert('uid-A', [_rec('t1')]),
        throwsA(isA<SyncNetworkError>()),
      );
    });

    test('ilk parça patlarsa sonraki parçalar GÖNDERİLMEZ', () async {
      final http = RecordingHttpClient(
        (_) => const FakeHttpResponse(status: 500, body: 'boom'),
      );
      final client = fakeSupabaseClient(http);
      addTearDown(client.dispose);

      await expectLater(
        SupabaseTokenRepository(
          client,
        ).pushUpsert('uid-A', [for (var i = 0; i < 600; i++) _rec('t$i')]),
        throwsA(isA<SyncError>()),
      );
      expect(http.requests, hasLength(1));
    });
  });

  group('tombstoneAllRemote', () {
    test(
      'PATCH {"deleted": true} + user_id=eq.<uid>; gövdede updated_at YOK',
      () async {
        final http = RecordingHttpClient();
        final client = fakeSupabaseClient(http);
        addTearDown(client.dispose);

        await SupabaseTokenRepository(client).tombstoneAllRemote('uid-A');

        final req = http.requests.single;
        expect(req.method, 'PATCH');
        expect(req.path, '/rest/v1/tokens');
        expect(req.json, {'deleted': true});
        expect(
          (req.json as Map).containsKey('updated_at'),
          isFalse,
          reason: 'trigger updated_at\'i kendi bumplar',
        );
        expect(req.query['user_id'], 'eq.uid-A');
        expect(req.query.containsKey('updated_at'), isFalse);
      },
    );

    test('hata → SyncError (çağıran best-effort olarak yutar)', () async {
      final http = RecordingHttpClient(
        (_) => const FakeHttpResponse(status: 500, body: 'boom'),
      );
      final client = fakeSupabaseClient(http);
      addTearDown(client.dispose);

      await expectLater(
        SupabaseTokenRepository(client).tombstoneAllRemote('uid-A'),
        throwsA(isA<SyncUnknownError>()),
      );
    });
  });

  group('tombstoneAllRemoteBefore', () {
    test('user_id=eq.<uid> + updated_at=lt.<iso> (reset anı kesimi)', () async {
      final http = RecordingHttpClient();
      final client = fakeSupabaseClient(http);
      addTearDown(client.dispose);

      await SupabaseTokenRepository(
        client,
      ).tombstoneAllRemoteBefore('uid-A', '2026-06-09T10:00:00.000Z');

      final req = http.requests.single;
      expect(req.method, 'PATCH');
      expect(req.json, {'deleted': true});
      expect(req.query['user_id'], 'eq.uid-A');
      expect(req.query['updated_at'], 'lt.2026-06-09T10:00:00.000Z');
    });
  });

  group('pullSince', () {
    test(
      'sinceIso null → tarih filtresi YOK; kolonlar + order=updated_at',
      () async {
        final http = RecordingHttpClient();
        final client = fakeSupabaseClient(http);
        addTearDown(client.dispose);

        final result = await SupabaseTokenRepository(
          client,
        ).pullSince('uid-A', null);

        final req = http.requests.single;
        expect(req.method, 'GET');
        expect(req.path, '/rest/v1/tokens');
        expect(req.query['user_id'], 'eq.uid-A');
        expect(
          req.query.containsKey('updated_at'),
          isFalse,
          reason: 'null cursor = full pull',
        );
        expect(
          req.query['select']!.split(','),
          containsAll(<String>[
            'id',
            'ciphertext',
            'nonce',
            'version',
            'updated_at',
            'deleted',
          ]),
        );
        expect(req.query['order'], startsWith('updated_at'));
        expect(result.rows, isEmpty);
        expect(result.malformedCount, 0);
        expect(result.safeCursorIso, isNull);
      },
    );

    test('sinceIso verilince updated_at=gt.<iso> filtresi eklenir', () async {
      final http = RecordingHttpClient();
      final client = fakeSupabaseClient(http);
      addTearDown(client.dispose);

      await SupabaseTokenRepository(
        client,
      ).pullSince('uid-A', '2026-06-09T10:00:00.000Z');

      expect(
        http.requests.single.query['updated_at'],
        'gt.2026-06-09T10:00:00.000Z',
      );
    });

    test(
      'satırlar RemoteTokenRow\'a çevrilir; cursor son valid updated_at',
      () async {
        final http = RecordingHttpClient(
          (_) => FakeHttpResponse.json([
            _serverRow('t1', seed: 1, updatedAt: '2026-06-09T10:00:00Z'),
            _serverRow(
              't2',
              seed: 2,
              updatedAt: '2026-06-09T11:00:00Z',
              version: 3,
              deleted: true,
            ),
          ]),
        );
        final client = fakeSupabaseClient(http);
        addTearDown(client.dispose);

        final result = await SupabaseTokenRepository(
          client,
        ).pullSince('uid-A', null);

        expect(result.rows.map((r) => r.id), ['t1', 't2']);
        expect(result.rows[0].blob.ciphertext, _blob(1).ciphertext);
        expect(result.rows[0].blob.nonce, _blob(1).nonce);
        expect(result.rows[0].version, 1);
        expect(result.rows[0].deleted, isFalse);
        expect(result.rows[1].version, 3);
        expect(result.rows[1].deleted, isTrue);
        expect(result.malformedCount, 0);
        expect(result.safeCursorIso, '2026-06-09T11:00:00.000Z');
      },
    );

    test(
      'bozuk satır ATLANIR; cursor İLK bozuktan ÖNCEye sabitlenir',
      () async {
        final http = RecordingHttpClient(
          (_) => FakeHttpResponse.json([
            _serverRow('ok1', seed: 1, updatedAt: '2026-06-09T10:00:00Z'),
            {
              'id': 'bad',
              'ciphertext': r'\xZZZZ', // geçersiz hex
              'nonce': ByteaCodec.encode(Uint8List(EncryptedBlob.nonceBytes)),
              'version': 1,
              'deleted': false,
              'updated_at': '2026-06-09T10:30:00Z',
            },
            _serverRow('ok2', seed: 2, updatedAt: '2026-06-09T11:00:00Z'),
          ]),
        );
        final client = fakeSupabaseClient(http);
        addTearDown(client.dispose);

        final result = await SupabaseTokenRepository(
          client,
        ).pullSince('uid-A', null);

        expect(result.rows.map((r) => r.id), ['ok1', 'ok2']);
        expect(result.malformedCount, 1);
        expect(
          result.safeCursorIso,
          '2026-06-09T10:00:00.000Z',
          reason: 'bozuk satırdan SONRAsı cursor ile atlanamaz (gap)',
        );
      },
    );

    test('403 → SyncPermissionDenied; 500 → SyncUnknownError', () async {
      final forbidden = RecordingHttpClient(
        (_) => const FakeHttpResponse(status: 403, body: 'forbidden'),
      );
      final c1 = fakeSupabaseClient(forbidden);
      addTearDown(c1.dispose);
      await expectLater(
        SupabaseTokenRepository(c1).pullSince('uid-A', null),
        throwsA(isA<SyncPermissionDenied>()),
      );

      final broken = RecordingHttpClient(
        (_) => const FakeHttpResponse(status: 500, body: 'boom'),
      );
      final c2 = fakeSupabaseClient(broken);
      addTearDown(c2.dispose);
      await expectLater(
        SupabaseTokenRepository(c2).pullSince('uid-A', null),
        throwsA(isA<SyncUnknownError>()),
      );
    });
  });
}
