import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/otp/otp_algorithm.dart';
import 'package:project_auth/features/import_export/data/aegis_parser.dart';
import 'package:project_auth/features/import_export/data/twofas_parser.dart';
import 'package:project_auth/features/import_export/domain/dedupe.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/import/$name').readAsStringSync())
        as Map<String, dynamic>;

OtpAccount _account({
  String secret = 'JBSWY3DPEHPK3PXP',
  String? issuer = 'GitHub',
  String accountName = 'alice@example.com',
  OtpType type = OtpType.totp,
  OtpAlgorithm algorithm = OtpAlgorithm.sha1,
  int digits = 6,
  int period = 30,
  int counter = 0,
}) =>
    OtpAccount(
      secret: secret,
      issuer: issuer,
      accountName: accountName,
      type: type,
      algorithm: algorithm,
      digits: digits,
      period: period,
      counter: counter,
    );

void main() {
  group('dedupeKey — secret canonicalization', () {
    test('lower case, spaces and padding produce the same key', () {
      expect(
        dedupeKey(_account(secret: 'jbswy3dp ehpk3pxp=')),
        dedupeKey(_account(secret: 'JBSWY3DPEHPK3PXP')),
      );
    });

    test('dashes and mixed case produce the same key', () {
      expect(
        dedupeKey(_account(secret: 'JbSw-Y3dP-EhPk-3pXp')),
        dedupeKey(_account(secret: 'JBSWY3DPEHPK3PXP')),
      );
    });

    test('the secret component is upper-case and unpadded', () {
      expect(dedupeKey(_account(secret: 'jbswy3dpehpk3pxp')),
          endsWith(' JBSWY3DPEHPK3PXP'));
    });

    test('a different secret produces a different key', () {
      expect(
        dedupeKey(_account(secret: 'GEZDGNBVGY3TQOJQ')),
        isNot(dedupeKey(_account(secret: 'JBSWY3DPEHPK3PXP'))),
      );
    });
  });

  group('dedupeKey — issuer and account name', () {
    test('issuer case and surrounding whitespace are ignored', () {
      expect(
        dedupeKey(_account(issuer: '  gitHUB ')),
        dedupeKey(_account(issuer: 'GitHub')),
      );
    });

    test('account name case and surrounding whitespace are ignored', () {
      expect(
        dedupeKey(_account(accountName: ' ALICE@Example.com ')),
        dedupeKey(_account(accountName: 'alice@example.com')),
      );
    });

    test('a null issuer and an empty issuer collapse to the same key', () {
      expect(
        dedupeKey(_account(issuer: null)),
        dedupeKey(_account(issuer: '')),
      );
    });

    test('a different issuer produces a different key', () {
      expect(
        dedupeKey(_account(issuer: 'GitLab')),
        isNot(dedupeKey(_account(issuer: 'GitHub'))),
      );
    });

    test('a different account name produces a different key', () {
      expect(
        dedupeKey(_account(accountName: 'bob@example.com')),
        isNot(dedupeKey(_account(accountName: 'alice@example.com'))),
      );
    });
  });

  group('dedupeKey — fields deliberately outside the key', () {
    test('the generated id does not affect the key', () {
      expect(dedupeKey(_account()), dedupeKey(_account()));
    });

    test('type, digits, period and counter do not affect the key', () {
      final totp = _account();
      final hotp = _account(type: OtpType.hotp, digits: 8, counter: 99);
      expect(dedupeKey(hotp), dedupeKey(totp));

      final slower = _account(period: 60, algorithm: OtpAlgorithm.sha512);
      expect(dedupeKey(slower), dedupeKey(totp));
    });
  });

  group('dedupeKey — parsed files', () {
    test('the same Aegis token exported twice yields one key', () {
      final parsed = const AegisParser().parse(_fixture('aegis_plain_v1.json'));
      // Rows 1 and 2 are the same token written with different secret
      // formatting and issuer capitalization.
      expect(dedupeKey(parsed.accounts[0]), dedupeKey(parsed.accounts[1]));
      expect(parsed.accounts[0].id, isNot(parsed.accounts[1].id));
    });

    test('distinct Aegis tokens in one file yield distinct keys', () {
      final parsed = const AegisParser().parse(_fixture('aegis_plain_v1.json'));
      final keys = parsed.accounts.map(dedupeKey).toSet();
      expect(keys, hasLength(4)); // 5 accounts, rows 1 and 2 collapse
    });

    test('the same token exported from Aegis and 2FAS yields one key', () {
      final aegis = const AegisParser()
          .parse(_fixture('aegis_plain_v1.json'))
          .accounts
          .first;
      final twofas =
          const TwoFasParser().parse(_fixture('twofas_v4.json')).accounts.first;
      expect(dedupeKey(twofas), dedupeKey(aegis));
    });

    test('every 2FAS token in one file has a distinct key', () {
      final parsed = const TwoFasParser().parse(_fixture('twofas_v4.json'));
      expect(parsed.accounts.map(dedupeKey).toSet(),
          hasLength(parsed.accounts.length));
    });
  });
}
