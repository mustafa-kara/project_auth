/// Phase 5 Patch 1 — BackupService export/import against the shared FakeCrypto.
///
/// The fake binds both the key (derived from password + salt) and the AAD, so
/// wrong-password and parameter-downgrade behaviour can be asserted on the host
/// VM. The real Argon2id/XChaCha20 round-trip lives in
/// `integration_test/backup_service_test.dart`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/crypto_exceptions.dart';
import 'package:project_auth/core/crypto/key_handle.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/otp/otp_algorithm.dart';
import 'package:project_auth/features/import_export/domain/backup_envelope.dart';
import 'package:project_auth/features/import_export/domain/backup_service.dart';
import 'package:project_auth/features/import_export/domain/import_exceptions.dart';
import 'package:project_auth/features/import_export/domain/import_models.dart';

import '../../support/fake_crypto.dart';

const _password = 'Yedek-Parola12!';
const _secret = 'JBSWY3DPEHPK3PXP';

OtpAccount _acc(String name, {String? issuer, String? id}) => OtpAccount(
  id: id,
  secret: _secret,
  type: OtpType.totp,
  accountName: name,
  issuer: issuer,
);

/// Counts `deriveKek` calls so a test can prove validation short-circuits first.
class _CountingCrypto extends BackupFakeCrypto {
  int deriveCalls = 0;

  @override
  Future<KeyHandle> deriveKek({
    required String password,
    required Uint8List salt,
    required int opsLimit,
    required int memLimit,
  }) {
    deriveCalls++;
    return super.deriveKek(
      password: password,
      salt: salt,
      opsLimit: opsLimit,
      memLimit: memLimit,
    );
  }
}

void main() {
  late FakeCrypto crypto;
  late BackupService service;

  setUp(() {
    crypto = BackupFakeCrypto();
    service = BackupService(crypto);
  });

  Future<Map<String, dynamic>> exportJson(List<OtpAccount> accounts) async =>
      jsonDecode(
            await service.export(
              accounts: accounts,
              password: _password,
              now: DateTime.utc(2026, 9, 2, 10, 11, 12),
            ),
          )
          as Map<String, dynamic>;

  group('export', () {
    test(
      'writes a valid envelope with the crypto backend\'s KDF params',
      () async {
        final json = await exportJson([
          _acc('a@example.com', issuer: 'GitHub'),
        ]);
        final params = crypto.defaultKdfParams();

        expect(json['format'], 'projectauth-backup');
        expect(json['version'], 1);
        expect(json['createdAt'], '2026-09-02T10:11:12.000Z');
        expect((json['kdf'] as Map)['alg'], 'argon2id');
        expect((json['kdf'] as Map)['opslimit'], params.opsLimit);
        expect((json['kdf'] as Map)['memlimit'], params.memLimit);
        expect(
          base64Decode((json['kdf'] as Map)['salt'] as String).length,
          params.saltBytes,
        );
        expect((json['cipher'] as Map)['alg'], 'xchacha20poly1305-ietf');
        expect(json.containsKey('aad'), isFalse);
      },
    );

    test('the envelope leaks no plaintext token data', () async {
      final serialized = await service.export(
        accounts: [_acc('a@example.com', issuer: 'GitHub')],
        password: _password,
      );
      expect(serialized.contains(_secret), isFalse);
      expect(serialized.contains('a@example.com'), isFalse);
      expect(serialized.contains('GitHub'), isFalse);
      expect(serialized.contains(_password), isFalse);
    });

    test('two exports of the same vault use different salts', () async {
      final a = await exportJson([_acc('a')]);
      final b = await exportJson([_acc('a')]);
      expect((a['kdf'] as Map)['salt'], isNot((b['kdf'] as Map)['salt']));
    });

    test('a weak password is rejected before any KDF work', () async {
      await expectLater(
        service.export(accounts: [_acc('a')], password: 'short1!'),
        throwsA(isA<WeakPasswordException>()),
      );
    });

    test(
      'a long single-class password is rejected (3 classes required)',
      () async {
        await expectLater(
          service.export(accounts: [_acc('a')], password: 'aaaaaaaaaaaaaaaa'),
          throwsA(isA<WeakPasswordException>()),
        );
      },
    );

    test('an empty vault still produces a valid, openable envelope', () async {
      final serialized = await service.export(
        accounts: [],
        password: _password,
      );
      expect(
        await service.import(json: serialized, password: _password),
        isEmpty,
      );
    });
  });

  group('import', () {
    test('round-trip preserves every field, id included', () async {
      final original = OtpAccount(
        secret: _secret,
        type: OtpType.hotp,
        accountName: 'hotp@example.com',
        issuer: 'Bank',
        algorithm: OtpAlgorithm.sha256,
        digits: 8,
        period: 60,
        counter: 42,
      );
      final serialized = await service.export(
        accounts: [original],
        password: _password,
      );
      final restored = await service.import(
        json: serialized,
        password: _password,
      );

      expect(restored, hasLength(1));
      expect(restored.single.id, original.id);
      expect(restored.single, original);
    });

    test('round-trip preserves order for many accounts', () async {
      final accounts = [_acc('a'), _acc('b'), _acc('c')];
      final serialized = await service.export(
        accounts: accounts,
        password: _password,
      );
      final restored = await service.import(
        json: serialized,
        password: _password,
      );
      expect(restored.map((a) => a.accountName), ['a', 'b', 'c']);
    });

    test('wrong password → WrongBackupPasswordException', () async {
      final serialized = await service.export(
        accounts: [_acc('a')],
        password: _password,
      );
      await expectLater(
        service.import(json: serialized, password: 'Baska-Parola12!'),
        throwsA(isA<WrongBackupPasswordException>()),
      );
    });

    test('tampered ciphertext → WrongBackupPasswordException', () async {
      final json = await exportJson([_acc('a')]);
      final ct = base64Decode(json['ciphertext'] as String);
      ct[ct.length - 1] ^= 0xff;
      json['ciphertext'] = base64Encode(ct);
      await expectLater(
        service.import(json: jsonEncode(json), password: _password),
        throwsA(isA<WrongBackupPasswordException>()),
      );
    });

    test(
      'opslimit downgrade → decrypt fails thanks to the AAD binding',
      () async {
        final json = await exportJson([_acc('a')]);
        final original = (json['kdf'] as Map)['opslimit'] as int;
        (json['kdf'] as Map)['opslimit'] = original - 1;
        expect(
          original - 1,
          greaterThanOrEqualTo(BackupEnvelope.minOpsLimit),
          reason:
              'the downgraded value must still pass range validation, '
              'otherwise this would only prove the range check',
        );
        await expectLater(
          service.import(json: jsonEncode(json), password: _password),
          throwsA(isA<WrongBackupPasswordException>()),
        );
      },
    );

    test(
      'memlimit downgrade → decrypt fails thanks to the AAD binding',
      () async {
        final json = await exportJson([_acc('a')]);
        (json['kdf'] as Map)['memlimit'] = BackupEnvelope.minMemLimit;
        await expectLater(
          service.import(json: jsonEncode(json), password: _password),
          throwsA(isA<WrongBackupPasswordException>()),
        );
      },
    );

    test('swapped salt → decrypt fails (salt is authenticated too)', () async {
      final json = await exportJson([_acc('a')]);
      (json['kdf'] as Map)['salt'] = base64Encode(Uint8List(16));
      await expectLater(
        service.import(json: jsonEncode(json), password: _password),
        throwsA(isA<WrongBackupPasswordException>()),
      );
    });

    test('not JSON at all → FormatException', () async {
      await expectLater(
        service.import(json: 'not json', password: _password),
        throwsA(isA<FormatException>()),
      );
    });

    test('a JSON array root → FormatException', () async {
      await expectLater(
        service.import(json: '[]', password: _password),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'a foreign format → FormatException, never a password error',
      () async {
        await expectLater(
          service.import(
            json: jsonEncode({'db': {}, 'header': {}}),
            password: _password,
          ),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'a newer envelope version → UnsupportedBackupVersionException',
      () async {
        final json = await exportJson([_acc('a')]);
        json['version'] = BackupService.supportedVersion + 1;
        await expectLater(
          service.import(json: jsonEncode(json), password: _password),
          throwsA(isA<UnsupportedBackupVersionException>()),
        );
      },
    );

    test(
      'validation runs before the KDF (no derive on a malformed file)',
      () async {
        final json = await exportJson([_acc('a')]);
        (json['kdf'] as Map)['opslimit'] = 999;
        final failing = _CountingCrypto();
        await expectLater(
          BackupService(
            failing,
          ).import(json: jsonEncode(json), password: _password),
          throwsA(isA<FormatException>()),
        );
        expect(failing.deriveCalls, 0);
      },
    );
  });

  group('importDetailed — malformed records', () {
    /// Builds an envelope whose payload we control, so a record that cannot be
    /// rebuilt into an [OtpAccount] can be injected.
    Future<String> sealPayload(Map<String, dynamic> payload) async {
      final params = crypto.defaultKdfParams();
      final salt = crypto.randomBytes(params.saltBytes);
      final kek = await crypto.deriveKek(
        password: _password,
        salt: salt,
        opsLimit: params.opsLimit,
        memLimit: params.memLimit,
      );
      final blob = crypto.encrypt(
        plaintext: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
        key: kek,
        aad: BackupEnvelope.aadFor(
          kdfAlg: BackupEnvelope.kdfAlgArgon2id,
          opsLimit: params.opsLimit,
          memLimit: params.memLimit,
          salt: salt,
          cipherAlg: BackupEnvelope.cipherAlgXChaCha20,
        ),
      );
      kek.dispose();
      return jsonEncode(
        BackupEnvelope(
          createdAt: DateTime.utc(2026),
          opsLimit: params.opsLimit,
          memLimit: params.memLimit,
          salt: salt,
          blob: blob,
        ).toJson(),
      );
    }

    test('a broken record is skipped, the good ones still restore', () async {
      final serialized = await sealPayload({
        'exportedAt': '2026-09-02T10:11:12.000Z',
        'accounts': [
          _acc('good@example.com', issuer: 'GitHub').toJson(),
          {'type': 'totp', 'secret': '!!!not base32!!!', 'accountName': 'bad'},
        ],
      });

      final payload = await service.importDetailed(
        json: serialized,
        password: _password,
      );
      expect(payload.accounts.map((a) => a.accountName), ['good@example.com']);
      expect(payload.skipped, hasLength(1));
      expect(payload.skipped.single.reason, SkipReason.invalidFields);
      expect(payload.skipped.single.label, 'bad');
      expect(payload.exportedAt, DateTime.utc(2026, 9, 2, 10, 11, 12));
    });

    test(
      'import() hides the skipped records; importDetailed() exposes them',
      () async {
        final serialized = await sealPayload({
          'accounts': [
            _acc('good').toJson(),
            {'type': 'nope', 'secret': _secret, 'accountName': 'x'},
          ],
        });
        expect(
          await service.import(json: serialized, password: _password),
          hasLength(1),
        );
        expect(
          (await service.importDetailed(
            json: serialized,
            password: _password,
          )).skipped,
          hasLength(1),
        );
      },
    );

    test('the skip label never carries the secret', () async {
      final serialized = await sealPayload({
        'accounts': [
          {
            'type': 'totp',
            'secret': _secret,
            'accountName': 'x',
            'digits': 99,
            'issuer': 'Acme',
          },
        ],
      });
      final payload = await service.importDetailed(
        json: serialized,
        password: _password,
      );
      expect(payload.accounts, isEmpty);
      expect(payload.skipped.single.label, 'Acme (x)');
      expect(payload.skipped.single.label!.contains(_secret), isFalse);
    });

    test('a non-object entry is skipped without a label', () async {
      final serialized = await sealPayload({
        'accounts': [_acc('good').toJson(), 'garbage'],
      });
      final payload = await service.importDetailed(
        json: serialized,
        password: _password,
      );
      expect(payload.accounts, hasLength(1));
      expect(payload.skipped.single.label, isNull);
    });

    test('a payload without an "accounts" list → FormatException', () async {
      final serialized = await sealPayload({'accounts': 'nope'});
      await expectLater(
        service.importDetailed(json: serialized, password: _password),
        throwsA(isA<FormatException>()),
      );
    });

    test('a missing exportedAt is tolerated', () async {
      final serialized = await sealPayload({
        'accounts': [_acc('a').toJson()],
      });
      final payload = await service.importDetailed(
        json: serialized,
        password: _password,
      );
      expect(payload.exportedAt, isNull);
      expect(payload.accounts, hasLength(1));
    });

    // --- Phase 5 Patch 3 (K1/K2): tags ride inside the payload only ---
    test(
      'a pre-Patch-3 payload (no "tags" key) restores with empty tags',
      () async {
        // Exactly what an older client wrote: the key is simply absent.
        final legacy = _acc('legacy@example.com', issuer: 'GitHub').toJson()
          ..remove('tags');
        expect(legacy.containsKey('tags'), isFalse);
        final serialized = await sealPayload({
          'accounts': [legacy],
        });

        final payload = await service.importDetailed(
          json: serialized,
          password: _password,
        );
        expect(payload.accounts.single.tags, isEmpty);
        expect(payload.skipped, isEmpty);
      },
    );

    test(
      'a payload whose "tags" is the wrong type skips ONLY that record',
      () async {
        final serialized = await sealPayload({
          'accounts': [
            _acc('good@example.com', issuer: 'GitHub').toJson(),
            _acc('bad@example.com', issuer: 'ACME').toJson()..['tags'] = 'iş',
          ],
        });

        final payload = await service.importDetailed(
          json: serialized,
          password: _password,
        );
        expect(payload.accounts.map((a) => a.accountName), [
          'good@example.com',
        ]);
        expect(payload.skipped.single.reason, SkipReason.invalidFields);
        expect(payload.skipped.single.label, 'ACME (bad@example.com)');
      },
    );
  });

  group('tags round trip (Faz 5 Patch 3)', () {
    test('tags survive export → import unchanged, in order', () async {
      final accounts = <OtpAccount>[
        _acc(
          'alice@example.com',
          issuer: 'GitHub',
        ).copyWith(tags: ['iş', 'ev']),
        _acc('bob@example.com', issuer: 'ACME'),
      ];

      final json = await service.export(
        accounts: accounts,
        password: _password,
      );
      final restored = await service.import(json: json, password: _password);

      expect(restored, accounts, reason: 'props include tags → full equality');
      expect(restored[0].tags, ['iş', 'ev']);
      expect(restored[1].tags, isEmpty);
    });

    test('the envelope version stays 1 — tags do NOT bump it (K1)', () async {
      final tagged = [
        _acc('alice@example.com', issuer: 'GitHub').copyWith(tags: ['iş']),
      ];
      final json = await service.export(accounts: tagged, password: _password);

      expect((jsonDecode(json) as Map<String, dynamic>)['version'], 1);
      expect(BackupService.supportedVersion, 1);
    });

    test(
      'an untagged export is byte-identical to a pre-Patch-3 one (K2)',
      () async {
        // The payload — not the envelope, whose salt/nonce are random — is what
        // must not change: no "tags" key anywhere for an untagged vault.
        final json = await service.export(
          accounts: [_acc('alice@example.com', issuer: 'GitHub')],
          password: _password,
        );
        final payload = await service.importDetailed(
          json: json,
          password: _password,
        );
        expect(payload.accounts.single.toJson().containsKey('tags'), isFalse);
      },
    );

    test('normalization is applied on the way back in', () async {
      // A hand-edited/foreign backup can carry a dirty list; it is cleaned, not
      // rejected (K4).
      final serialized = await sealPayloadFor(crypto, {
        'accounts': [
          _acc('alice@example.com', issuer: 'GitHub').toJson()
            ..['tags'] = ['  iş ', 'iş', '', 'g' * 40],
        ],
      });
      final payload = await service.importDetailed(
        json: serialized,
        password: _password,
      );
      expect(payload.accounts.single.tags, [
        'iş',
        'g' * OtpAccount.maxTagRunes,
      ]);
    });
  });
}

/// Same envelope-sealing helper as `importDetailed — malformed records`, hoisted
/// so the tags group can inject a payload of its own.
Future<String> sealPayloadFor(
  FakeCrypto crypto,
  Map<String, dynamic> payload,
) async {
  final params = crypto.defaultKdfParams();
  final salt = crypto.randomBytes(params.saltBytes);
  final kek = await crypto.deriveKek(
    password: _password,
    salt: salt,
    opsLimit: params.opsLimit,
    memLimit: params.memLimit,
  );
  final blob = crypto.encrypt(
    plaintext: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    key: kek,
    aad: BackupEnvelope.aadFor(
      kdfAlg: BackupEnvelope.kdfAlgArgon2id,
      opsLimit: params.opsLimit,
      memLimit: params.memLimit,
      salt: salt,
      cipherAlg: BackupEnvelope.cipherAlgXChaCha20,
    ),
  );
  return jsonEncode(
    BackupEnvelope(
      createdAt: DateTime.utc(2026, 9, 2),
      opsLimit: params.opsLimit,
      memLimit: params.memLimit,
      salt: salt,
      blob: blob,
    ).toJson(),
  );
}
