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

    test('B3 — MD5 is reported as a capability gap, not a broken file', () {
      final skip = result.skipped.single;
      expect(skip.reason, SkipReason.unsupportedType);
      expect(skip.label, 'WeirdAlgo (weird@example.com)');
      expect(skip.detail, 'algorithm=MD5');
      expect(skip.detail, isNot(contains('ONSWG4TFOQ')));
    });

    test('fresh ids are generated for every account', () {
      expect(result.accounts.map((a) => a.id).toSet(), hasLength(4));
    });

    test('groupId resolves to exactly one tag', () {
      expect(result.accounts[0].tags, ['Work']);
      expect(result.accounts[2].tags, ['Kişisel']);
    });

    test('groupId: null yields no tag', () {
      expect(result.accounts[1].tags, isEmpty);
    });

    test('an unknown groupId yields no tag and NO skipped entry', () {
      expect(result.accounts[3].tags, isEmpty);
      expect(result.skipped, hasLength(1)); // still only the MD5 capability gap
      expect(result.skipped.single.detail, 'algorithm=MD5');
    });
  });

  // --- Phase 5 Patch 3 (K6): groups → tags ---
  group('groups → tags', () {
    /// A 2FAS envelope with an explicit root `groups` index.
    Map<String, dynamic> exportWithGroups(
            List<Object?> groups, List<Object?> services) =>
        {
          'services': services,
          'groups': groups,
          'updatedAt': 1699999999500,
          'schemaVersion': 4,
          'appOrigin': 'android',
        };

    Map<String, dynamic> group(String id, String name) =>
        {'id': id, 'name': name, 'updatedAt': 1699999999500};

    List<String> tagsOf(Map<String, dynamic> export) =>
        parser.parse(export).accounts.single.tags;

    test('a service carries AT MOST one tag', () {
      final export = exportWithGroups([
        group('g1', 'Work'),
        group('g2', 'Kişisel'),
      ], [
        {..._service(), 'groupId': 'g2'},
      ]);
      expect(tagsOf(export), ['Kişisel']);
    });

    test('the group id is trimmed before the lookup', () {
      final export = exportWithGroups([
        group('g1', 'Work'),
      ], [
        {..._service(), 'groupId': '  g1  '},
      ]);
      expect(tagsOf(export), ['Work']);
    });

    // 2FAS writes uuid strings, but exports in the wild (and hand-edited files)
    // carry plain integer ids. Both halves are compared in their STRING form,
    // so a `7` that fails to match a `"7"` cannot silently cost the token its
    // group. The NAME is not given the same tolerance: a number is not a label.
    test('an integer group id matches an integer groupId', () {
      final export = exportWithGroups([
        {'id': 7, 'name': 'Work'},
      ], [
        {..._service(), 'groupId': 7},
      ]);
      expect(tagsOf(export), ['Work']);
    });

    test('an integer groupId matches a string group id', () {
      final export = exportWithGroups([
        group('7', 'Work'),
      ], [
        {..._service(), 'groupId': 7},
      ]);
      expect(tagsOf(export), ['Work']);
    });

    test('a string groupId matches an integer group id', () {
      final export = exportWithGroups([
        {'id': 7, 'name': 'Work'},
      ], [
        {..._service(), 'groupId': ' 7 '},
      ]);
      expect(tagsOf(export), ['Work']);
    });

    test('a non-scalar groupId is still no group at all', () {
      for (final bad in <Object?>[true, <String>[], <String, Object?>{}]) {
        final export = exportWithGroups([
          {'id': 7, 'name': 'Work'},
          group('true', 'Bool'),
        ], [
          {..._service(), 'groupId': bad},
        ]);
        expect(tagsOf(export), isEmpty, reason: 'groupId: $bad');
      }
    });

    test('a numeric group NAME is still rejected', () {
      final export = exportWithGroups([
        {'id': 7, 'name': 7},
      ], [
        {..._service(), 'groupId': 7},
      ]);
      expect(tagsOf(export), isEmpty);
    });

    test('a 40-character group name is clipped to 32 runes', () {
      final export = exportWithGroups([
        group('g1', 'g' * 40),
      ], [
        {..._service(), 'groupId': 'g1'},
      ]);
      expect(tagsOf(export).single, 'g' * OtpAccount.maxTagRunes);
    });

    test('the first row wins a duplicated group id', () {
      final export = exportWithGroups([
        group('g1', 'Once'),
        group('g1', 'Twice'),
      ], [
        {..._service(), 'groupId': 'g1'},
      ]);
      expect(tagsOf(export), ['Once']);
    });

    test('a broken groups index never costs the service its token', () {
      final broken = <Map<String, dynamic>>[
        // no such group
        exportWithGroups(const [], [
          {..._service(), 'groupId': 'nobody'},
        ]),
        // groups index is not a list
        {
          'services': [
            {..._service(), 'groupId': 'g1'},
          ],
          'groups': 'Work',
          'schemaVersion': 4,
        },
        // groups key absent entirely (older schemas)
        {
          'services': [
            {..._service(), 'groupId': 'g1'},
          ],
          'schemaVersion': 4,
        },
        // groupId is a number that matches nothing in the index
        exportWithGroups([
          group('g1', 'Work'),
        ], [
          {..._service(), 'groupId': 7},
        ]),
        // groupId is a type that can never be an id
        exportWithGroups([
          group('g1', 'Work'),
        ], [
          {..._service(), 'groupId': <String>['g1']},
        ]),
        // group rows are missing halves / wrongly typed / unmatched
        exportWithGroups([
          {'id': 'g1'},
          {'name': 'Work'},
          {'id': 'g2', 'name': '  '},
          {'id': 5, 'name': 'Work'},
          'not a map',
        ], [
          {..._service(), 'groupId': 'g1'},
        ]),
      ];

      for (final export in broken) {
        final result = parser.parse(export);
        expect(result.accounts, hasLength(1));
        expect(result.accounts.single.tags, isEmpty);
        expect(result.skipped, isEmpty,
            reason: 'a group problem must never produce a SkippedEntry');
      }
    });

    test('a skipped service stays skipped regardless of its group', () {
      final export = exportWithGroups([
        group('g1', 'Work'),
      ], [
        {
          ..._service(otp: const {'tokenType': 'YANDEX'}),
          'groupId': 'g1',
        },
      ]);
      final result = parser.parse(export);
      expect(result.accounts, isEmpty);
      expect(result.skipped.single.reason, SkipReason.unsupportedType);
    });
  });

  group('twofas_steam_hotp.json — Steam and HOTP', () {
    late ParsedImport result;

    setUp(() => result = parser.parse(_fixture('twofas_steam_hotp.json')));

    test('four services import, three are skipped', () {
      expect(result.accounts, hasLength(4));
      expect(result.skipped, hasLength(3));
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

    test('tokenType is matched case-insensitively', () {
      final a = result.accounts[2];
      expect(a.type, OtpType.hotp); // file says "hotp"
      expect(a.accountName, 'user2');
      expect(a.counter, 3);
    });

    test('B1 — a TOTP service whose issuer reads "steam" stays a TOTP', () {
      // 2FAS has a first-class STEAM tokenType, so a service the file calls
      // TOTP is a TOTP. Promoting it would force digits to 5 and produce codes
      // that do not work.
      final a = result.accounts[3];
      expect(a.type, OtpType.totp);
      expect(a.issuer, 'steam');
      expect(a.accountName, 'player');
      expect(a.digits, 6); // exactly what the file said
      expect(a.period, 30);
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

    test('B3 — SHA224 (in the 2FAS enum) is unsupportedType', () {
      final skip = result.skipped[2];
      expect(skip.reason, SkipReason.unsupportedType);
      expect(skip.label, 'Sha224 (user5)');
      expect(skip.detail, 'algorithm=SHA224');
    });

    test('no secret from the file leaks into a skip record', () {
      const secrets = [
        'JBSWY3DPEHPK3PXP',
        'GEZDGNBVGY3TQOJQ',
        'MFRGGZDFMZTWQ2LK',
        'KRSXG5CTMVRXEZLU',
        'MZXW6YTBOI',
        'NB2W45DFOIZA',
        'ONSWG4TFOQ',
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

    test('B2 — a non-empty "reference" alone flags an encrypted export', () {
      // 2FAS' own predicate: BackupContent.isEncrypted is
      // `reference.isNullOrBlank().not()`. An export can carry the reference
      // without servicesEncrypted; it is still password-protected.
      final json = _export(const [])
        ..['reference'] = 'Y2lwaGVy:c2FsdA==:aXY=';
      expect(
        () => parser.parse(json),
        throwsA(isA<EncryptedSourceException>()
            .having((e) => e.source, 'source', ImportSource.twofas)),
      );
    });

    test('B2 — an empty or blank "reference" is not treated as encrypted', () {
      for (final reference in const ['', '   ']) {
        final json = _export([_service()])..['reference'] = reference;
        expect(parser.parse(json).accounts, hasLength(1));
      }
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

    test('B1 — neither otp.issuer nor the service name can promote a TOTP',
        () {
      for (final otp in const [
        {
          'account': 'user',
          'digits': 6,
          'period': 30,
          'algorithm': 'SHA1',
          'tokenType': 'TOTP',
        },
        {
          'account': 'user',
          'issuer': 'Steam',
          'digits': 6,
          'period': 30,
          'algorithm': 'SHA1',
          'tokenType': 'TOTP',
        },
      ]) {
        final result =
            parser.parse(_export([_service(name: 'Steam', otp: otp)]));
        final a = result.accounts.single;
        expect(a.type, OtpType.totp);
        expect(a.digits, 6);
      }
    });

    test('HOTP still accepts the defensive "initialCounter" field name', () {
      // Not written by the official exporter (BackupService.Otp only has
      // `counter`); kept for third-party writers that claim the 2FAS shape.
      final result = parser.parse(_export([
        _service(otp: const {
          'account': 'a',
          'tokenType': 'HOTP',
          'initialCounter': 12,
        }),
      ]));
      expect(result.accounts.single.type, OtpType.hotp);
      expect(result.accounts.single.counter, 12);
    });

    test('B3 — SHA224/SHA384/MD5 are unsupportedType, not invalidFields', () {
      for (final algorithm in const ['SHA224', 'sha-384', 'MD5']) {
        final result = parser.parse(_export([
          _service(otp: {
            'account': 'a',
            'tokenType': 'TOTP',
            'algorithm': algorithm,
          }),
        ]));
        expect(result.accounts, isEmpty);
        expect(result.skipped.single.reason, SkipReason.unsupportedType);
        expect(result.skipped.single.detail,
            'algorithm=${algorithm.toUpperCase().replaceAll('-', '')}');
      }
    });

    test('B3 — an algorithm outside the 2FAS enum stays invalidFields', () {
      final result = parser.parse(_export([
        _service(otp: const {
          'account': 'a',
          'tokenType': 'TOTP',
          'algorithm': 'BLAKE2B',
        }),
      ]));
      expect(result.skipped.single.reason, SkipReason.invalidFields);
      expect(result.skipped.single.detail, contains('BLAKE2B'));
    });

    test('B4 — name, otp.issuer and otp.account are capped at 512 bytes', () {
      final long = 'A' * 513;
      final cases = <String, Map<String, dynamic>>{
        'issuer': {'account': 'a', 'issuer': long, 'tokenType': 'TOTP'},
        'account': {'account': long, 'tokenType': 'TOTP'},
      };
      cases.forEach((field, otp) {
        final result = parser.parse(_export([_service(otp: otp)]));
        expect(result.accounts, isEmpty, reason: field);
        expect(result.skipped.single.reason, SkipReason.invalidFields);
        expect(result.skipped.single.detail, contains(field));
      });

      final byName = parser.parse(_export([
        _service(name: long, otp: const {'account': 'a', 'tokenType': 'TOTP'}),
      ]));
      expect(byName.accounts, isEmpty);
      expect(byName.skipped.single.detail, contains('name'));
    });

    test('B4 — the ceiling counts bytes, not code units', () {
      final result = parser.parse(_export([
        _service(otp: {'account': 'ş' * 300, 'tokenType': 'TOTP'}),
      ]));
      expect(result.accounts, isEmpty);
      expect(result.skipped.single.reason, SkipReason.invalidFields);

      final ok = parser.parse(_export([
        _service(otp: {'account': 'ş' * 256, 'tokenType': 'TOTP'}),
      ]));
      expect(ok.accounts.single.accountName, 'ş' * 256);
    });

    test('B4 — an oversized label is clamped before it reaches the preview',
        () {
      final result = parser.parse(_export([
        _service(otp: {'account': 'C' * 5000, 'tokenType': 'TOTP'}),
      ]));
      final label = result.skipped.single.label!;
      expect(label.length, lessThan(200));
      expect(label, contains('…'));
    });

    test('B6 — a redacted link secret gets a 2FAS-specific detail', () {
      final result = parser.parse(_export([
        const {
          'name': 'Redacted',
          'otp': {
            'account': 'user',
            'tokenType': 'TOTP',
            'link':
                'otpauth://totp/Redacted:user?secret=%5Bhidden%5D&issuer=X',
          },
        },
      ]));
      expect(result.accounts, isEmpty);
      final skip = result.skipped.single;
      expect(skip.reason, SkipReason.invalidSecret);
      expect(skip.detail, contains('2FAS'));
      expect(skip.detail, contains('re-export'));
      // The placeholder is not a secret, but the rule still holds: nothing that
      // sat in the secret position is echoed back.
      expect(skip.detail, isNot(contains('hidden')));
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
