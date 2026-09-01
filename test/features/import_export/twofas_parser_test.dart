import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/otp/otp_algorithm.dart';
import 'package:project_auth/features/import_export/data/twofas_parser.dart';
import 'package:project_auth/features/import_export/domain/import_exceptions.dart';
import 'package:project_auth/features/import_export/domain/import_models.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/import/$name').readAsStringSync())
        as Map<String, dynamic>;

/// Minimal 2FAS envelope around [services].
Map<String, dynamic> _export(List<Object?> services) => {
      'services': services,
      'groups': <Object?>[],
      'updatedAt': 1699999999500,
      'schemaVersion': 4,
      'appOrigin': 'android',
    };

Map<String, dynamic> _service({
  String name = 'Acme',
  String secret = 'JBSWY3DPEHPK3PXP',
  Map<String, dynamic> otp = const {
    'label': 'Acme',
    'account': 'user',
    'issuer': 'Acme',
    'digits': 6,
    'period': 30,
    'algorithm': 'SHA1',
    'tokenType': 'TOTP',
  },
}) =>
    {'name': name, 'secret': secret, 'otp': otp};

void main() {
  const parser = TwoFasParser();

  test('declares the twofas source', () {
    expect(parser.source, ImportSource.twofas);
    expect(parser.parse(_export(const [])).source, ImportSource.twofas);
  });

  group('twofas_v4.json — field mapping', () {
    late ParsedImport result;

    setUp(() => result = parser.parse(_fixture('twofas_v4.json')));

    test('four services import, one is skipped', () {
      expect(result.accounts, hasLength(4));
      expect(result.skipped, hasLength(1));
    });

    test('row 1 — secret comes from the service root, otp fills the rest', () {
      final a = result.accounts[0];
      expect(a.type, OtpType.totp);
      expect(a.issuer, 'GitHub');
      expect(a.accountName, 'alice@example.com');
      expect(a.secret, 'JBSWY3DPEHPK3PXP');
      expect(a.algorithm, OtpAlgorithm.sha1);
      expect(a.digits, 6);
      expect(a.period, 30);
      expect(a.counter, 0);
    });

    test('row 2 — empty issuer and empty name become a null issuer', () {
      final a = result.accounts[1];
      expect(a.issuer, isNull);
      expect(a.accountName, 'personal@example.org');
      expect(a.algorithm, OtpAlgorithm.sha256);
      expect(a.digits, 8);
      expect(a.period, 60);
    });

    test('row 3 — no usable name anywhere falls back to the placeholder', () {
      final a = result.accounts[2];
      expect(a.issuer, isNull);
      expect(a.accountName, '(isimsiz)');
    });

    test('row 4 — a service without tokenType is treated as TOTP', () {
      final a = result.accounts[3];
      expect(a.type, OtpType.totp);
      expect(a.issuer, 'Legacy');
      expect(a.accountName, 'legacy@example.com');
      expect(a.digits, 6); // absent in file → default
      expect(a.period, 30); // absent in file → default
      expect(a.algorithm, OtpAlgorithm.sha1); // absent in file → default
    });

    test('unknown algorithm is skipped with a labelled record', () {
      final skip = result.skipped.single;
      expect(skip.reason, SkipReason.invalidFields);
      expect(skip.label, 'WeirdAlgo (weird@example.com)');
      expect(skip.detail, contains('MD5'));
      expect(skip.detail, isNot(contains('ONSWG4TFOQ')));
    });

    test('fresh ids are generated for every account', () {
      expect(result.accounts.map((a) => a.id).toSet(), hasLength(4));
    });
  });

  group('twofas_steam_hotp.json — Steam and HOTP', () {
    late ParsedImport result;

    setUp(() => result = parser.parse(_fixture('twofas_steam_hotp.json')));

    test('four services import, two are skipped', () {
      expect(result.accounts, hasLength(4));
      expect(result.skipped, hasLength(2));
    });

    test('tokenType STEAM maps to a Steam token', () {
      final a = result.accounts[0];
      expect(a.type, OtpType.steam);
      expect(a.issuer, 'Steam');
      expect(a.accountName, 'gaben');
      expect(a.digits, 5);
      expect(a.period, 30);
      expect(a.algorithm, OtpAlgorithm.sha1);
    });

    test('HOTP reads "counter"', () {
      final a = result.accounts[1];
      expect(a.type, OtpType.hotp);
      expect(a.accountName, 'user1');
      expect(a.counter, 7);
    });

    test('HOTP also reads the alternative "initialCounter" name', () {
      final a = result.accounts[2];
      expect(a.type, OtpType.hotp);
      expect(a.accountName, 'user2');
      expect(a.counter, 3);
    });

    test('D5 — TOTP with issuer "steam" is promoted, digits forced to 5', () {
      final a = result.accounts[3];
      expect(a.type, OtpType.steam);
      expect(a.issuer, 'steam');
      expect(a.accountName, 'player');
      expect(a.digits, 5); // file said 6
    });

    test('HOTP without a counter is skipped, never defaulted to 0', () {
      final skip = result.skipped[0];
      expect(skip.reason, SkipReason.invalidFields);
      expect(skip.label, 'HOTP NoCounter (user3)');
      expect(skip.detail, contains('counter'));
    });

    test('an unknown tokenType is skipped as unsupportedType', () {
      final skip = result.skipped[1];
      expect(skip.reason, SkipReason.unsupportedType);
      expect(skip.label, 'Mystery (user4)');
      expect(skip.detail, contains('MOTP'));
    });

    test('no secret from the file leaks into a skip record', () {
      const secrets = [
        'JBSWY3DPEHPK3PXP',
        'GEZDGNBVGY3TQOJQ',
        'MFRGGZDFMZTWQ2LK',
        'KRSXG5CTMVRXEZLU',
        'MZXW6YTBOI',
        'NB2W45DFOIZA',
      ];
      for (final skip in result.skipped) {
        final text = '${skip.label ?? ''} ${skip.detail ?? ''}';
        for (final secret in secrets) {
          expect(text, isNot(contains(secret)));
        }
      }
    });
  });

  group('encrypted sources', () {
    test('servicesEncrypted → EncryptedSourceException(twofas)', () {
      expect(
        () => parser.parse(_fixture('twofas_encrypted.json')),
        throwsA(isA<EncryptedSourceException>()
            .having((e) => e.source, 'source', ImportSource.twofas)),
      );
    });

    test('an empty servicesEncrypted value is not treated as encrypted', () {
      final json = _export([_service()])..['servicesEncrypted'] = '';
      expect(parser.parse(json).accounts, hasLength(1));
    });

    test('a blank-only servicesEncrypted value is not treated as encrypted',
        () {
      final json = _export(const [])..['servicesEncrypted'] = '   ';
      expect(parser.parse(json).accounts, isEmpty);
    });
  });

  group('malformed root structures', () {
    test('services is not a list', () {
      expect(
        () => parser.parse(const {'services': 'nope'}),
        throwsA(isA<MalformedImportFileException>()),
      );
    });

    test('services key is missing entirely', () {
      expect(
        () => parser.parse(const {'schemaVersion': 4}),
        throwsA(isA<MalformedImportFileException>()),
      );
    });
  });

  group('per-service tolerance', () {
    test('a non-object service is skipped, the rest still import', () {
      final result = parser.parse(_export(['garbage', _service()]));
      expect(result.accounts, hasLength(1));
      expect(result.skipped.single.reason, SkipReason.invalidFields);
      expect(result.skipped.single.label, isNull);
    });

    test('a service without an otp object still imports as TOTP', () {
      final result = parser.parse(_export([
        const {'name': 'Bare', 'secret': 'JBSWY3DPEHPK3PXP'},
      ]));
      final a = result.accounts.single;
      expect(a.type, OtpType.totp);
      expect(a.issuer, 'Bare');
      expect(a.accountName, 'Bare');
      expect(a.digits, 6);
      expect(a.period, 30);
    });

    test('a missing root secret falls back to the otpauth link', () {
      final result = parser.parse(_export([
        const {
          'name': 'Linked',
          'otp': {
            'account': 'linked@example.com',
            'issuer': 'Linked',
            'tokenType': 'TOTP',
            'link':
                'otpauth://totp/Linked:linked%40example.com?secret=GEZDGNBVGY3TQOJQ&issuer=Linked',
          },
        },
      ]));
      expect(result.accounts.single.secret, 'GEZDGNBVGY3TQOJQ');
    });

    test('a non-otpauth link is not used as a secret source', () {
      final result = parser.parse(_export([
        const {
          'name': 'Linked',
          'otp': {'tokenType': 'TOTP', 'link': 'https://example.com/?secret=X'},
        },
      ]));
      expect(result.accounts, isEmpty);
      expect(result.skipped.single.reason, SkipReason.invalidSecret);
    });

    test('an undecodable secret is invalidSecret and never echoed back', () {
      final result = parser.parse(_export([_service(secret: 'not-base32!!')]));
      expect(result.skipped.single.reason, SkipReason.invalidSecret);
      expect(result.skipped.single.detail, isNot(contains('not-base32')));
    });

    test('tokenType is case-insensitive', () {
      final result = parser.parse(_export([
        _service(otp: const {'account': 'a', 'tokenType': 'steam'}),
      ]));
      expect(result.accounts.single.type, OtpType.steam);
    });

    test('digits below and above the contract are rejected', () {
      for (final digits in const [5, 9]) {
        final result = parser.parse(_export([
          _service(otp: {'account': 'a', 'tokenType': 'TOTP', 'digits': digits}),
        ]));
        expect(result.accounts, isEmpty);
        expect(result.skipped.single.reason, SkipReason.invalidFields);
        expect(result.skipped.single.detail, contains('digits=$digits'));
      }
    });

    test('period bounds 1 and 600 are accepted, 0 and 601 are rejected', () {
      for (final period in const [1, 600]) {
        final result = parser.parse(_export([
          _service(otp: {'account': 'a', 'tokenType': 'TOTP', 'period': period}),
        ]));
        expect(result.accounts.single.period, period);
      }
      for (final period in const [0, 601]) {
        final result = parser.parse(_export([
          _service(otp: {'account': 'a', 'tokenType': 'TOTP', 'period': period}),
        ]));
        expect(result.skipped.single.reason, SkipReason.invalidFields);
      }
    });

    test('numeric strings and integer-valued doubles are accepted', () {
      final result = parser.parse(_export([
        _service(otp: const {
          'account': 'a',
          'tokenType': 'TOTP',
          'digits': '8',
          'period': 60.0,
        }),
      ]));
      expect(result.accounts.single.digits, 8);
      expect(result.accounts.single.period, 60);
    });

    test('fractional numbers are rejected, never truncated', () {
      final result = parser.parse(_export([
        _service(otp: const {
          'account': 'a',
          'tokenType': 'TOTP',
          'period': 30.5,
        }),
      ]));
      expect(result.accounts, isEmpty);
      expect(result.skipped.single.reason, SkipReason.invalidFields);
      expect(result.skipped.single.detail, contains('period'));
    });

    test('steam keeps an in-range period but ignores an out-of-range one', () {
      final kept = parser.parse(_export([
        _service(otp: const {
          'account': 'a',
          'tokenType': 'STEAM',
          'period': 45,
        }),
      ]));
      expect(kept.accounts.single.period, 45);

      final fallback = parser.parse(_export([
        _service(otp: const {
          'account': 'a',
          'tokenType': 'STEAM',
          'period': 5000,
        }),
      ]));
      expect(fallback.accounts.single.period, 30);
      expect(fallback.accounts.single.digits, 5);
    });

    test('negative HOTP counter is rejected', () {
      final result = parser.parse(_export([
        _service(otp: const {
          'account': 'a',
          'tokenType': 'HOTP',
          'counter': -1,
        }),
      ]));
      expect(result.accounts, isEmpty);
      expect(result.skipped.single.reason, SkipReason.invalidFields);
    });

    test('wrongly typed names do not crash label building', () {
      final result = parser.parse(_export([
        const {
          'name': 7,
          'secret': 'not-base32!!',
          'otp': {'account': <String, dynamic>{}, 'tokenType': 'TOTP'},
        },
      ]));
      expect(result.skipped.single.reason, SkipReason.invalidSecret);
      expect(result.skipped.single.label, isNull);
    });
  });
}
