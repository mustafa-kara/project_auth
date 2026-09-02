import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/features/import_export/domain/import_format_detector.dart';
import 'package:project_auth/features/import_export/domain/import_models.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/import/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  group('detectSource — recognized formats', () {
    test('Aegis plain export → aegis', () {
      expect(detectSource(_fixture('aegis_plain_v1.json')), ImportSource.aegis);
    });

    test('Aegis encrypted export is still detected as aegis', () {
      // Must NOT fall through to "unknown": the parser has to be reached so it
      // can raise EncryptedSourceException with actionable guidance.
      expect(
        detectSource(_fixture('aegis_encrypted_slots.json')),
        ImportSource.aegis,
      );
    });

    test('Aegis mixed-type export → aegis', () {
      expect(
        detectSource(_fixture('aegis_mixed_types.json')),
        ImportSource.aegis,
      );
    });

    test('structurally broken Aegis file still fingerprints as aegis', () {
      expect(detectSource(_fixture('malformed.json')), ImportSource.aegis);
    });

    test('2FAS v4 export → twofas', () {
      expect(detectSource(_fixture('twofas_v4.json')), ImportSource.twofas);
    });

    test('2FAS encrypted export → twofas', () {
      expect(
        detectSource(_fixture('twofas_encrypted.json')),
        ImportSource.twofas,
      );
    });

    test('2FAS steam/hotp export → twofas', () {
      expect(
        detectSource(_fixture('twofas_steam_hotp.json')),
        ImportSource.twofas,
      );
    });

    test('our own backup envelope → projectauthBackup', () {
      expect(
        detectSource(const {
          'format': 'projectauth-backup',
          'version': 1,
          'createdAt': '2026-09-02T10:11:12.000Z',
          'kdf': {'alg': 'argon2id'},
          'cipher': {'alg': 'xchacha20poly1305-ietf'},
          'ciphertext': 'AAAA',
        }),
        ImportSource.projectauthBackup,
      );
    });

    test('servicesEncrypted alone is enough for twofas', () {
      expect(
        detectSource(const {'servicesEncrypted': 'abc'}),
        ImportSource.twofas,
      );
    });
  });

  group('detectSource — ordering', () {
    test('our backup wins over Aegis and 2FAS fingerprints', () {
      expect(
        detectSource(const {
          'format': 'projectauth-backup',
          'db': <String, dynamic>{},
          'header': <String, dynamic>{},
          'services': <dynamic>[],
        }),
        ImportSource.projectauthBackup,
      );
    });

    test('Aegis wins over 2FAS when both fingerprints are present', () {
      expect(
        detectSource(const {
          'db': <String, dynamic>{},
          'header': <String, dynamic>{},
          'services': <dynamic>[],
        }),
        ImportSource.aegis,
      );
    });
  });

  group('detectSource — unknown', () {
    test('empty object', () {
      expect(detectSource(const {}), ImportSource.unknown);
    });

    test('"db" without "header" is not Aegis', () {
      expect(
        detectSource(const {'db': <String, dynamic>{}}),
        ImportSource.unknown,
      );
    });

    test('"header" without "db" is not Aegis', () {
      expect(
        detectSource(const {'header': <String, dynamic>{}}),
        ImportSource.unknown,
      );
    });

    test('unrelated JSON object', () {
      expect(
        detectSource(const {'accounts': <dynamic>[], 'exportedAt': 'now'}),
        ImportSource.unknown,
      );
    });

    test('foreign "format" value is not our backup', () {
      expect(
        detectSource(const {'format': 'someone-elses-backup'}),
        ImportSource.unknown,
      );
    });

    test('non-string "format" does not crash', () {
      expect(detectSource(const {'format': 42}), ImportSource.unknown);
    });
  });
}
