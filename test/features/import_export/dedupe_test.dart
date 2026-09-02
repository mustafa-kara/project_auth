import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/otp/otp_algorithm.dart';
import 'package:project_auth/features/import_export/data/aegis_parser.dart';
import 'package:project_auth/features/import_export/data/twofas_parser.dart';
import 'package:project_auth/features/import_export/domain/dedupe.dart';
import 'package:project_auth/features/vault/domain/catalog_repository.dart';
import 'package:project_auth/features/vault/domain/issuer_catalog.dart';

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

  // --- Audit A2: the issuer component uses the shared slug normalization ---
  group('dedupeKey — issuer slug normalization', () {
    test('punctuation and inner spacing in the issuer are ignored', () {
      expect(
        dedupeKey(_account(issuer: 'Amazon Web Services')),
        dedupeKey(_account(issuer: 'amazon-web-services')),
      );
      expect(
        dedupeKey(_account(issuer: 'Proton Mail')),
        dedupeKey(_account(issuer: 'protonmail')),
      );
    });

    test('the issuer component is the IssuerAvatar/IssuerCatalog slug', () {
      // Same normalization the avatar and the catalog index use, so the three
      // cannot disagree about what "the same issuer" means.
      expect(dedupeKey(_account(issuer: 'Git Hub!')), startsWith('github '));
    });

    test('an alias is NOT bridged by the slug alone — that needs the catalog',
        () {
      // Documents the limit called out in the doc comment: "github.com" slugs
      // to `githubcom`. Only `canonicalizerFor` maps it onto "GitHub".
      expect(
        dedupeKey(_account(issuer: 'github.com')),
        isNot(dedupeKey(_account(issuer: 'GitHub'))),
      );
    });
  });

  group('canonicalizerFor — catalog-backed issuer alignment', () {
    IssuerCatalog catalog() => IssuerCatalog(const [
          CatalogService(
              id: '1', name: 'GitHub', issuer: 'github.com', logoUrl: null),
          CatalogService(
              id: '2', name: 'GitHub', issuer: null, logoUrl: null),
        ]);

    test('an alias issuer becomes the canonical catalog name', () {
      final canon = canonicalizerFor(catalog())(_account(issuer: 'github.com'));
      expect(canon.issuer, 'GitHub');
      expect(canon.id, isNotNull);
    });

    test('canonicalized alias and canonical name share one dedupe key', () {
      final canonicalize = canonicalizerFor(catalog());
      expect(
        dedupeKey(canonicalize(_account(issuer: 'github.com'))),
        dedupeKey(canonicalize(_account(issuer: 'GitHub'))),
        reason: 'the whole point of A2: vault side and file side must match',
      );
    });

    test('an unknown issuer and an empty catalog are both no-ops', () {
      final account = _account(issuer: 'Nowhere Inc');
      expect(canonicalizerFor(catalog())(account), same(account));
      expect(canonicalizerFor(IssuerCatalog.empty())(_account()), isNotNull);
      expect(canonicalizerFor(IssuerCatalog.empty())(account).issuer,
          'Nowhere Inc');
    });

    test('every other field survives the rewrite', () {
      final account = _account(issuer: 'github.com', type: OtpType.hotp, counter: 7);
      final canon = canonicalizerFor(catalog())(account);
      expect(canon.id, account.id);
      expect(canon.secret, account.secret);
      expect(canon.accountName, account.accountName);
      expect(canon.type, OtpType.hotp);
      expect(canon.counter, 7);
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
