import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/otp/otp_algorithm.dart';
import 'package:project_auth/features/import_export/data/aegis_parser.dart';
import 'package:project_auth/features/import_export/domain/import_exceptions.dart';
import 'package:project_auth/features/import_export/domain/import_models.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/import/$name').readAsStringSync())
        as Map<String, dynamic>;

/// Minimal Aegis envelope around [entries], for cases no fixture should carry.
Map<String, dynamic> _vault(List<Object?> entries) => {
      'version': 1,
      'header': <String, dynamic>{'slots': null, 'params': null},
      'db': <String, dynamic>{'version': 3, 'entries': entries},
    };

Map<String, dynamic> _entry({
  String type = 'totp',
  String issuer = 'Acme',
  String name = 'user',
  Map<String, dynamic> info = const {
    'secret': 'JBSWY3DPEHPK3PXP',
    'algo': 'SHA1',
    'digits': 6,
    'period': 30,
  },
}) =>
    {'type': type, 'issuer': issuer, 'name': name, 'info': info};

void main() {
  const parser = AegisParser();

  test('declares the aegis source', () {
    expect(parser.source, ImportSource.aegis);
    expect(parser.parse(_vault(const [])).source, ImportSource.aegis);
  });

  group('aegis_plain_v1.json — field mapping', () {
    late ParsedImport result;

    setUp(() => result = parser.parse(_fixture('aegis_plain_v1.json')));

    test('every entry is imported and nothing is skipped', () {
      expect(result.accounts, hasLength(5));
      expect(result.skipped, isEmpty);
    });

    test('row 1 — full TOTP entry maps every field', () {
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

    test('row 2 — issuer/name are trimmed, raw secret text is preserved', () {
      final a = result.accounts[1];
      expect(a.issuer, 'github');
      expect(a.accountName, 'alice@example.com');
      expect(a.secret, 'jbswy3dp ehpk3pxp=');
    });

    test('row 3 — empty issuer becomes null; sha256/8 digits/60s survive', () {
      final a = result.accounts[2];
      expect(a.issuer, isNull);
      expect(a.accountName, 'bob@example.com');
      expect(a.algorithm, OtpAlgorithm.sha256);
      expect(a.digits, 8);
      expect(a.period, 60);
    });

    test('row 4 — empty name falls back to the issuer', () {
      final a = result.accounts[3];
      expect(a.issuer, 'ACME');
      expect(a.accountName, 'ACME');
    });

    test('row 5 — empty name and issuer fall back to the placeholder', () {
      final a = result.accounts[4];
      expect(a.issuer, isNull);
      expect(a.accountName, '(isimsiz)');
    });

    test('the Aegis uuid is discarded and fresh ids are generated', () {
      final ids = result.accounts.map((a) => a.id).toSet();
      expect(ids, hasLength(result.accounts.length));
      expect(ids.contains('3f1a6c2e-0b41-4a9d-9d1e-8f0b2c7a5d10'), isFalse);
    });

    test('db.groups uuids become tags, in file order', () {
      expect(result.accounts[0].tags, ['Work']);
      expect(result.accounts[1].tags, ['Kişisel']);
      expect(result.accounts[2].tags, ['Work', 'Kişisel']);
    });

    test('an unknown group uuid yields no tag and NO skipped entry', () {
      expect(result.accounts[3].tags, isEmpty);
      expect(result.skipped, isEmpty);
      expect(result.accounts, hasLength(5),
          reason: 'a stale group reference must never drop a token');
    });

    test('an empty "groups" list yields no tags', () {
      expect(result.accounts[4].tags, isEmpty);
    });
  });

  // --- Phase 5 Patch 3 (K6): groups → tags ---
  group('groups → tags', () {
    /// An Aegis envelope with an explicit `db.groups` index.
    Map<String, dynamic> vaultWithGroups(
            List<Object?> groups, List<Object?> entries) =>
        {
          'version': 1,
          'header': <String, dynamic>{'slots': null, 'params': null},
          'db': <String, dynamic>{
            'version': 3,
            'entries': entries,
            'groups': groups,
          },
        };

    Map<String, dynamic> group(String uuid, String name) =>
        {'uuid': uuid, 'name': name};

    List<String> tagsOf(Map<String, dynamic> vault) =>
        parser.parse(vault).accounts.single.tags;

    test('the legacy singular "group" field carries the NAME verbatim', () {
      // Pre-uuid Aegis exports wrote the group name straight onto the entry.
      final vault = _vault([
        {..._entry(), 'group': '  Work  '},
      ]);
      expect(tagsOf(vault), ['Work']);
    });

    test('uuid references and the legacy field can coexist', () {
      final vault = vaultWithGroups([
        group('g1', 'Work'),
      ], [
        {..._entry(), 'groups': ['g1'], 'group': 'Eski'},
      ]);
      expect(tagsOf(vault), ['Work', 'Eski']);
    });

    test('a 40-character group name is clipped to 32 runes', () {
      final vault = vaultWithGroups([
        group('g1', 'g' * 40),
      ], [
        {..._entry(), 'groups': ['g1']},
      ]);
      expect(tagsOf(vault).single, 'g' * OtpAccount.maxTagRunes);
    });

    test('12 groups on one entry become the first 8 tags', () {
      final uuids = [for (var i = 0; i < 12; i++) 'g$i'];
      final vault = vaultWithGroups(
        [for (final u in uuids) group(u, 'ad-$u')],
        [
          {..._entry(), 'groups': uuids},
        ],
      );
      expect(tagsOf(vault), [for (var i = 0; i < 8; i++) 'ad-g$i']);
    });

    test('duplicate references collapse into one tag', () {
      final vault = vaultWithGroups([
        group('g1', 'Work'),
        group('g2', 'Work'),
      ], [
        {..._entry(), 'groups': ['g1', 'g2', 'g1']},
      ]);
      expect(tagsOf(vault), ['Work']);
    });

    test('a broken groups index never costs the entry its token', () {
      // Every shape below is nonsense; each one must still import the token
      // with zero tags and zero skipped entries.
      final broken = <Map<String, dynamic>>[
        vaultWithGroups(const [], [
          {..._entry(), 'groups': ['nobody']},
        ]),
        // groups index is not a list
        {
          'version': 1,
          'header': <String, dynamic>{'slots': null, 'params': null},
          'db': <String, dynamic>{
            'version': 3,
            'groups': 'Work',
            'entries': [
              {..._entry(), 'groups': ['g1']},
            ],
          },
        },
        // entry.groups is not a list
        vaultWithGroups([
          group('g1', 'Work'),
        ], [
          {..._entry(), 'groups': 'g1'},
        ]),
        // references are not strings
        vaultWithGroups([
          group('g1', 'Work'),
        ], [
          {..._entry(), 'groups': [1, null, {'uuid': 'g1'}]},
        ]),
        // group rows are missing halves / wrongly typed
        vaultWithGroups([
          {'uuid': 'g1'},
          {'name': 'Work'},
          {'uuid': 'g2', 'name': '   '},
          {'uuid': 3, 'name': 'Work'},
          'not a map',
        ], [
          {..._entry(), 'groups': ['g1', 'g2']},
        ]),
        // legacy field is not a string
        _vault([
          {..._entry(), 'group': 42},
        ]),
      ];

      for (final vault in broken) {
        final result = parser.parse(vault);
        expect(result.accounts, hasLength(1));
        expect(result.accounts.single.tags, isEmpty);
        expect(result.skipped, isEmpty,
            reason: 'a group problem must never produce a SkippedEntry');
      }
    });

    test('the first row wins a duplicated group uuid', () {
      final vault = vaultWithGroups([
        group('g1', 'Once'),
        group('g1', 'Twice'),
      ], [
        {..._entry(), 'groups': ['g1']},
      ]);
      expect(tagsOf(vault), ['Once']);
    });

    test('a skipped entry stays skipped regardless of its group', () {
      final vault = vaultWithGroups([
        group('g1', 'Work'),
      ], [
        {
          ..._entry(type: 'yandex'),
          'groups': ['g1'],
        },
      ]);
      final result = parser.parse(vault);
      expect(result.accounts, isEmpty);
      expect(result.skipped.single.reason, SkipReason.unsupportedType);
    });
  });

  group('aegis_mixed_types.json — types, Steam and per-entry skips', () {
    late ParsedImport result;

    setUp(() => result = parser.parse(_fixture('aegis_mixed_types.json')));

    test('four entries survive, five are skipped', () {
      expect(result.accounts, hasLength(4));
      expect(result.skipped, hasLength(5));
    });

    test('HOTP keeps its counter', () {
      final a = result.accounts[1];
      expect(a.type, OtpType.hotp);
      expect(a.issuer, 'Bank');
      expect(a.accountName, 'user1');
      expect(a.counter, 5);
      expect(a.period, 30); // absent in file → default
    });

    test('native steam entry keeps digits 5 / sha1', () {
      final a = result.accounts[2];
      expect(a.type, OtpType.steam);
      expect(a.issuer, 'Steam');
      expect(a.accountName, 'gaben');
      expect(a.digits, 5);
      expect(a.period, 30);
      expect(a.algorithm, OtpAlgorithm.sha1);
    });

    test('B1 — a totp entry whose issuer reads "Steam" stays a TOTP', () {
      // Aegis has a first-class "steam" type, so a file that says "totp" means
      // TOTP. Promoting it would force digits to 5 and produce wrong codes.
      final a = result.accounts[3];
      expect(a.type, OtpType.totp);
      expect(a.issuer, 'Steam');
      expect(a.accountName, 'player');
      expect(a.digits, 6); // exactly what the file said
      expect(a.period, 30);
    });

    test('icon, icon_mime and icon_hash are ignored, not mapped', () {
      final a = result.accounts[0];
      expect(a.issuer, 'GitHub');
      expect(a.accountName, 'alice@example.com');
    });

    test('unsupported types are skipped with their type name as detail', () {
      final yandex = result.skipped[0];
      expect(yandex.reason, SkipReason.unsupportedType);
      expect(yandex.label, 'Yandex (yandex-user)');
      expect(yandex.detail, contains('yandex'));

      // A realistic MOTP entry (MD5 / 10s / 6 digits / pin): rejected on its
      // type, before its MD5 algo is ever looked at.
      final motp = result.skipped[3];
      expect(motp.reason, SkipReason.unsupportedType);
      expect(motp.label, 'Legacy (motp-user)');
      expect(motp.detail, contains('motp'));
      expect(motp.detail, isNot(contains('MD5')));
    });

    test('undecodable secret is skipped as invalidSecret', () {
      final broken = result.skipped[1];
      expect(broken.reason, SkipReason.invalidSecret);
      expect(broken.label, 'Broken (x)');
      expect(broken.detail, isNot(contains('not-base32')));
    });

    test('HOTP without a counter is skipped rather than defaulted to 0', () {
      final noCounter = result.skipped[2];
      expect(noCounter.reason, SkipReason.invalidFields);
      expect(noCounter.label, 'NoCounter (y)');
      expect(noCounter.detail, contains('counter'));
    });

    test('out-of-range digits is skipped', () {
      final bad = result.skipped[4];
      expect(bad.reason, SkipReason.invalidFields);
      expect(bad.label, 'BadDigits (d)');
      expect(bad.detail, contains('digits=9'));
    });

    test('no secret from the file leaks into a skip record', () {
      const secrets = [
        'JBSWY3DPEHPK3PXP',
        'GEZDGNBVGY3TQOJQ',
        'MFRGGZDFMZTWQ2LK',
        'NBSWY3DPEB3W64TMMQ',
        'KRSXG5CTMVRXEZLU',
        'ONSWG4TFOQ',
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
    test('non-empty header.slots → EncryptedSourceException(aegis)', () {
      expect(
        () => parser.parse(_fixture('aegis_encrypted_slots.json')),
        throwsA(isA<EncryptedSourceException>()
            .having((e) => e.source, 'source', ImportSource.aegis)),
      );
    });

    test('string "db" alone is enough to flag an encrypted vault', () {
      expect(
        () => parser.parse(const {
          'version': 1,
          'header': {'slots': null, 'params': null},
          'db': 'ZW5jcnlwdGVkLWJsb2I=',
        }),
        throwsA(isA<EncryptedSourceException>()),
      );
    });

    test('an empty slots list is NOT treated as encrypted', () {
      final result = parser.parse({
        'version': 1,
        'header': {'slots': <dynamic>[], 'params': null},
        'db': {'version': 3, 'entries': <dynamic>[]},
      });
      expect(result.accounts, isEmpty);
    });
  });

  group('malformed root structures', () {
    test('entries is an object instead of a list', () {
      expect(() => parser.parse(_fixture('malformed.json')),
          throwsA(isA<MalformedImportFileException>()));
    });

    test('db is not an object', () {
      expect(
        () => parser.parse(const {
          'header': {'slots': null},
          'db': 42,
        }),
        throwsA(isA<MalformedImportFileException>()),
      );
    });

    test('entries key is missing', () {
      expect(
        () => parser.parse(const {
          'header': {'slots': null},
          'db': {'version': 3},
        }),
        throwsA(isA<MalformedImportFileException>()),
      );
    });
  });

  group('per-entry tolerance', () {
    test('a non-object entry is skipped, the rest still import', () {
      final result = parser.parse(_vault(['garbage', _entry()]));
      expect(result.accounts, hasLength(1));
      expect(result.skipped.single.reason, SkipReason.invalidFields);
      expect(result.skipped.single.label, isNull);
    });

    test('missing info object is skipped', () {
      final result = parser.parse(_vault([
        {'type': 'totp', 'issuer': 'Acme', 'name': 'user'},
      ]));
      expect(result.accounts, isEmpty);
      expect(result.skipped.single.reason, SkipReason.invalidFields);
    });

    test('missing type is skipped as invalidFields', () {
      final result = parser.parse(_vault([
        {
          'issuer': 'Acme',
          'name': 'user',
          'info': const {'secret': 'JBSWY3DPEHPK3PXP'},
        },
      ]));
      expect(result.skipped.single.reason, SkipReason.invalidFields);
    });

    test('empty secret is invalidSecret', () {
      final result = parser.parse(_vault([
        _entry(info: const {'secret': '', 'algo': 'SHA1'}),
      ]));
      expect(result.skipped.single.reason, SkipReason.invalidSecret);
    });

    test('secret that decodes to zero bytes is invalidSecret', () {
      final result = parser.parse(_vault([
        _entry(info: const {'secret': '====', 'algo': 'SHA1'}),
      ]));
      expect(result.skipped.single.reason, SkipReason.invalidSecret);
    });

    test('digits below the contract is invalidFields', () {
      final result = parser.parse(_vault([
        _entry(info: const {'secret': 'JBSWY3DPEHPK3PXP', 'digits': 5}),
      ]));
      expect(result.skipped.single.reason, SkipReason.invalidFields);
      expect(result.skipped.single.detail, contains('digits=5'));
    });

    test('period 0 and period 601 are both rejected', () {
      for (final period in const [0, 601]) {
        final result = parser.parse(_vault([
          _entry(info: {'secret': 'JBSWY3DPEHPK3PXP', 'period': period}),
        ]));
        expect(result.accounts, isEmpty);
        expect(result.skipped.single.reason, SkipReason.invalidFields);
      }
    });

    test('period 1 and period 600 are both accepted', () {
      for (final period in const [1, 600]) {
        final result = parser.parse(_vault([
          _entry(info: {'secret': 'JBSWY3DPEHPK3PXP', 'period': period}),
        ]));
        expect(result.accounts.single.period, period);
      }
    });

    test('digits 6 and 8 are accepted', () {
      for (final digits in const [6, 8]) {
        final result = parser.parse(_vault([
          _entry(info: {'secret': 'JBSWY3DPEHPK3PXP', 'digits': digits}),
        ]));
        expect(result.accounts.single.digits, digits);
      }
    });

    test('numeric strings and integer-valued doubles are accepted', () {
      final result = parser.parse(_vault([
        _entry(info: const {
          'secret': 'JBSWY3DPEHPK3PXP',
          'digits': '8',
          'period': 60.0,
        }),
      ]));
      expect(result.accounts.single.digits, 8);
      expect(result.accounts.single.period, 60);
    });

    test('fractional numbers are rejected, never truncated', () {
      final result = parser.parse(_vault([
        _entry(info: const {'secret': 'JBSWY3DPEHPK3PXP', 'digits': 6.5}),
      ]));
      expect(result.accounts, isEmpty);
      expect(result.skipped.single.reason, SkipReason.invalidFields);
      expect(result.skipped.single.detail, contains('digits'));
    });

    test('missing algo defaults to sha1', () {
      final result = parser.parse(_vault([
        _entry(info: const {'secret': 'JBSWY3DPEHPK3PXP'}),
      ]));
      expect(result.accounts.single.algorithm, OtpAlgorithm.sha1);
    });

    test('sha512 and dashed spellings are accepted', () {
      final result = parser.parse(_vault([
        _entry(info: const {'secret': 'JBSWY3DPEHPK3PXP', 'algo': 'SHA-512'}),
      ]));
      expect(result.accounts.single.algorithm, OtpAlgorithm.sha512);
    });

    test('HOTP accepts the alternative "initialCounter" field name', () {
      final result = parser.parse(_vault([
        _entry(
          type: 'hotp',
          info: const {'secret': 'JBSWY3DPEHPK3PXP', 'initialCounter': 12},
        ),
      ]));
      expect(result.accounts.single.type, OtpType.hotp);
      expect(result.accounts.single.counter, 12);
    });

    test('negative HOTP counter is rejected', () {
      final result = parser.parse(_vault([
        _entry(
          type: 'hotp',
          info: const {'secret': 'JBSWY3DPEHPK3PXP', 'counter': -1},
        ),
      ]));
      expect(result.accounts, isEmpty);
      expect(result.skipped.single.reason, SkipReason.invalidFields);
    });

    test('steam keeps an in-range period but ignores an out-of-range one', () {
      final kept = parser.parse(_vault([
        _entry(
          type: 'steam',
          issuer: 'Steam',
          info: const {'secret': 'JBSWY3DPEHPK3PXP', 'period': 45},
        ),
      ]));
      expect(kept.accounts.single.period, 45);

      final fallback = parser.parse(_vault([
        _entry(
          type: 'steam',
          issuer: 'Steam',
          info: const {'secret': 'JBSWY3DPEHPK3PXP', 'period': 5000},
        ),
      ]));
      expect(fallback.accounts.single.period, 30);
      expect(fallback.accounts.single.digits, 5);
    });

    test('steam ignores a foreign algo instead of dropping the entry', () {
      final result = parser.parse(_vault([
        _entry(
          type: 'steam',
          issuer: 'Steam',
          info: const {'secret': 'JBSWY3DPEHPK3PXP', 'algo': 'MD5'},
        ),
      ]));
      expect(result.accounts.single.algorithm, OtpAlgorithm.sha1);
    });

    test('B3 — a known but uncomputable algorithm is unsupportedType', () {
      // SHA224/SHA384 are in the 2FAS algorithm enum and MD5 is what Aegis
      // writes for MOTP; none of them is something this app can compute. That
      // is a capability gap, not a broken file, so the taxonomy differs from a
      // name nobody writes.
      for (final algo in const ['SHA224', 'sha-384', 'MD5']) {
        final result = parser.parse(_vault([
          _entry(info: {'secret': 'JBSWY3DPEHPK3PXP', 'algo': algo}),
        ]));
        expect(result.accounts, isEmpty);
        expect(result.skipped.single.reason, SkipReason.unsupportedType);
        expect(result.skipped.single.detail,
            'algorithm=${algo.toUpperCase().replaceAll('-', '')}');
      }
    });

    test('B3 — an algorithm no authenticator writes stays invalidFields', () {
      final result = parser.parse(_vault([
        _entry(info: const {'secret': 'JBSWY3DPEHPK3PXP', 'algo': 'BLAKE2B'}),
      ]));
      expect(result.skipped.single.reason, SkipReason.invalidFields);
      expect(result.skipped.single.detail, contains('BLAKE2B'));
    });

    test('B4 — issuer over 512 UTF-8 bytes is rejected', () {
      final result = parser.parse(_vault([
        _entry(issuer: 'A' * 513),
      ]));
      expect(result.accounts, isEmpty);
      expect(result.skipped.single.reason, SkipReason.invalidFields);
      expect(result.skipped.single.detail, contains('issuer'));
      expect(result.skipped.single.detail, contains('512'));
    });

    test('B4 — name over 512 UTF-8 bytes is rejected', () {
      final result = parser.parse(_vault([
        _entry(name: 'b' * 513),
      ]));
      expect(result.accounts, isEmpty);
      expect(result.skipped.single.reason, SkipReason.invalidFields);
      expect(result.skipped.single.detail, contains('name'));
    });

    test('B4 — the ceiling counts bytes, not code units', () {
      // "ş" is two UTF-8 bytes: 300 of them are under 512 code units but over
      // the byte ceiling.
      final result = parser.parse(_vault([_entry(issuer: 'ş' * 300)]));
      expect(result.accounts, isEmpty);
      expect(result.skipped.single.reason, SkipReason.invalidFields);

      final ok = parser.parse(_vault([_entry(issuer: 'ş' * 256)]));
      expect(ok.accounts.single.issuer, 'ş' * 256);
    });

    test('B4 — an oversized label is clamped before it reaches the preview',
        () {
      final result = parser.parse(_vault([_entry(issuer: 'C' * 5000)]));
      final label = result.skipped.single.label!;
      expect(label.length, lessThan(200));
      expect(label, contains('…'));
    });

    test('wrongly typed issuer/name do not crash label building', () {
      final result = parser.parse(_vault([
        {
          'type': 'totp',
          'issuer': 42,
          'name': <String, dynamic>{},
          'info': const {'secret': 'not-base32!!'},
        },
      ]));
      expect(result.skipped.single.reason, SkipReason.invalidSecret);
      expect(result.skipped.single.label, isNull);
    });
  });
}
