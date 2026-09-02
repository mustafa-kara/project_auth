/// Phase 5 Patch 2 — `otpauth-migration://offline?data=…` → [MigrationBatch]
/// (plan §2).
///
/// Fixtures are synthesized by `test/support/protobuf_encoder.dart`; no real
/// Google Authenticator export is committed, since that would be a bundle of
/// live secrets in version control. The two golden vectors from the plan are
/// additionally pinned as hex so the decoder is checked against a value derived
/// independently of the encoder.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/base32.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/otp/otp_algorithm.dart';
import 'package:project_auth/features/import_export/data/google_auth_parser.dart';
import 'package:project_auth/features/import_export/data/protobuf_wire.dart';
import 'package:project_auth/features/import_export/domain/google_migration.dart';
import 'package:project_auth/features/import_export/domain/import_exceptions.dart';
import 'package:project_auth/features/import_export/domain/import_models.dart';

import '../../support/protobuf_encoder.dart';

/// Plan §1 vector A, pinned as hex/base64/URI.
const String _vectorASecretHex = '48656c6c6f21deadbeef';
const String _vectorASecretB32 = 'JBSWY3DPEHPK3PXP';
const String _vectorAPayloadHex =
    '0a2e0a0a48656c6c6f21deadbeef1211616c696365406578616d706c652e636f6d'
    '1a074578616d706c652001280130021001180120002800';
const String _vectorAUri =
    'otpauth-migration://offline?data='
    'Ci4KCkhlbGxvId6tvu8SEWFsaWNlQGV4YW1wbGUuY29tGgdFeGFtcGxlIAEoATACEAEYASAAKAA%3D';

/// Plan §1 vector B — `batch_id` -2, and a base64 form containing `+` and `/`.
const String _vectorBSecretHex = '3e3ffbefbefa00112233';
const String _vectorBPayloadHex =
    '0a170a0a3e3ffbefbefa001122331203626f62200128013002'
    '10011801200028feffffffffffffffff01';
const String _vectorBRawUri =
    'otpauth-migration://offline?data='
    'ChcKCj4/+++++gARIjMSA2JvYiABKAEwAhABGAEgACj+//////////8B';
const String _vectorBEncodedUri =
    'otpauth-migration://offline?data='
    'ChcKCj4%2F%2B%2B%2B%2B%2BgARIjMSA2JvYiABKAEwAhABGAEgACj%2B%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F8B';

/// A minimal, valid TOTP entry — the base every mapping test perturbs.
Uint8List _entry({
  List<int>? secret,
  String? name = 'alice@example.com',
  String? issuer,
  int? algorithm = ProtoAlgorithm.sha1,
  int? digits = ProtoDigits.six,
  int? type = ProtoOtpType.totp,
  int? counter,
}) => encodeOtpParameters(
  secret: secret ?? fromHex(_vectorASecretHex),
  name: name,
  issuer: issuer,
  algorithm: algorithm,
  digits: digits,
  type: type,
  counter: counter,
);

/// Parses a payload built from [entries] with default batch coordinates.
MigrationBatch _parse(List<Uint8List> entries) =>
    GoogleAuthParser.parsePayload(encodeMigrationPayload(entries: entries));

/// The single [SkippedEntry] a one-entry payload produced.
SkippedEntry _onlySkip(MigrationBatch batch) {
  expect(batch.accounts, isEmpty, reason: 'expected the entry to be skipped');
  expect(batch.skipped, hasLength(1));
  return batch.skipped.single;
}

void main() {
  group('looksLikeMigrationUri', () {
    test(
      'accepts the migration scheme, case-insensitively and with padding',
      () {
        expect(GoogleAuthParser.looksLikeMigrationUri(_vectorAUri), isTrue);
        expect(
          GoogleAuthParser.looksLikeMigrationUri(
            '  OTPAUTH-MIGRATION://offline?data=AA',
          ),
          isTrue,
        );
      },
    );

    test('rejects a plain otpauth:// token and unrelated text', () {
      expect(
        GoogleAuthParser.looksLikeMigrationUri(
          'otpauth://totp/a?secret=$_vectorASecretB32',
        ),
        isFalse,
      );
      expect(
        GoogleAuthParser.looksLikeMigrationUri('https://example.com'),
        isFalse,
      );
      expect(GoogleAuthParser.looksLikeMigrationUri(''), isFalse);
    });
  });

  group('golden vector A', () {
    test('the encoder reproduces the plan payload byte for byte', () {
      final built = encodeMigrationPayload(
        entries: [_entry(issuer: 'Example')],
      );
      expect(toHex(built), _vectorAPayloadHex);
    });

    test('the pinned URI maps to the expected account', () {
      final batch = GoogleAuthParser.parseUri(_vectorAUri);

      expect(batch.version, 1);
      expect(batch.batchSize, 1);
      expect(batch.batchIndex, 0);
      expect(batch.batchId, 0);
      expect(batch.skipped, isEmpty);
      expect(batch.accounts, hasLength(1));

      final account = batch.accounts.single;
      expect(account.secret, _vectorASecretB32);
      expect(account.type, OtpType.totp);
      expect(account.issuer, 'Example');
      expect(account.accountName, 'alice@example.com');
      expect(account.algorithm, OtpAlgorithm.sha1);
      expect(account.digits, 6);
      expect(account.period, 30);
      expect(account.counter, 0);
      expect(account.id, isNotEmpty);
    });

    test('the pinned hex payload decodes identically to the pinned URI', () {
      final fromBytes = GoogleAuthParser.parsePayload(
        fromHex(_vectorAPayloadHex),
      );
      final fromUri = GoogleAuthParser.parseUri(_vectorAUri);
      expect(fromBytes.accounts.single.secret, fromUri.accounts.single.secret);
      expect(
        fromBytes.accounts.single.accountName,
        fromUri.accounts.single.accountName,
      );
      expect(fromBytes.batchId, fromUri.batchId);
    });
  });

  group('golden vector B — negative batch_id and the "+" trap', () {
    test('the encoder reproduces the plan payload byte for byte', () {
      final built = encodeMigrationPayload(
        entries: [_entry(secret: fromHex(_vectorBSecretHex), name: 'bob')],
        batchId: -2,
      );
      expect(toHex(built), _vectorBPayloadHex);
    });

    test('the raw and the percent-encoded URI give the identical result', () {
      final raw = GoogleAuthParser.parseUri(_vectorBRawUri);
      final encoded = GoogleAuthParser.parseUri(_vectorBEncodedUri);

      for (final batch in [raw, encoded]) {
        expect(batch.batchId, -2, reason: 'sign-extended 10-byte varint');
        expect(batch.batchSize, 1);
        expect(batch.accounts, hasLength(1));
        expect(batch.accounts.single.accountName, 'bob');
        expect(
          batch.accounts.single.secret,
          Base32.encode(fromHex(_vectorBSecretHex)),
        );
      }
      expect(raw.accounts.single.secret, encoded.accounts.single.secret);
    });

    test(
      'REGRESSION: Uri.queryParameters would corrupt this payload — the hand '
      'split does not',
      () {
        // Proof the trap is real: the form-urlencoded reading turns each `+`
        // into a space, so the base64 no longer decodes to the same bytes.
        final viaQueryParameters = Uri.parse(
          _vectorBRawUri,
        ).queryParameters['data'];
        expect(viaQueryParameters, contains(' '));

        final parsed = GoogleAuthParser.parseUri(_vectorBRawUri);
        expect(
          parsed.accounts.single.secret,
          Base32.encode(fromHex(_vectorBSecretHex)),
        );
      },
    );
  });

  group('URI validation', () {
    test('a wrong scheme is refused', () {
      expect(
        () => GoogleAuthParser.parseUri('otpauth://offline?data=Ci4KCkhlbGxv'),
        throwsA(isA<MalformedMigrationUriException>()),
      );
    });

    test('a wrong host is refused', () {
      expect(
        () => GoogleAuthParser.parseUri(
          'otpauth-migration://online?data=Ci4KCkhlbGxv',
        ),
        throwsA(isA<MalformedMigrationUriException>()),
      );
    });

    test('scheme and host are matched case-insensitively', () {
      final upper = _vectorAUri
          .replaceFirst('otpauth-migration', 'OTPAUTH-MIGRATION')
          .replaceFirst('offline', 'OFFLINE');
      expect(GoogleAuthParser.parseUri(upper).accounts, hasLength(1));
    });

    test('a missing, empty or blank data parameter is refused', () {
      for (final uri in const [
        'otpauth-migration://offline',
        'otpauth-migration://offline?data=',
        'otpauth-migration://offline?other=AAAA',
        'otpauth-migration://offline?data=%3D%3D',
      ]) {
        expect(
          () => GoogleAuthParser.parseUri(uri),
          throwsA(isA<MalformedMigrationUriException>()),
          reason: uri,
        );
      }
    });

    test('a repeated "data" parameter resolves to the FIRST one', () {
      // Behaviour pin, not a preference: no legitimate export carries two
      // `data` parameters, so this only decides which half of a malformed QR
      // is rejected. `Uri.queryParameters` picks the first as well; pinning it
      // keeps a later refactor from silently drifting to "last wins".
      final first = base64.encode(encodeMigrationPayload(entries: [_entry()]));
      final second = base64.encode(
        encodeMigrationPayload(entries: [_entry(name: 'bob@example.com')]),
      );
      final batch = GoogleAuthParser.parseUri(
        'otpauth-migration://offline?data=$first&data=$second',
      );
      expect(batch.accounts.single.accountName, 'alice@example.com');

      // Mirror image: a broken FIRST value fails even though the second is
      // perfectly valid.
      expect(
        () => GoogleAuthParser.parseUri(
          'otpauth-migration://offline?data=!!!!&data=$second',
        ),
        throwsA(isA<MalformedMigrationUriException>()),
      );
    });

    test('an empty string is refused', () {
      expect(
        () => GoogleAuthParser.parseUri('   '),
        throwsA(isA<MalformedMigrationUriException>()),
      );
    });

    test('undecodable base64 is refused', () {
      expect(
        () =>
            GoogleAuthParser.parseUri('otpauth-migration://offline?data=!!!!'),
        throwsA(isA<MalformedMigrationUriException>()),
      );
      // Length 1 mod 4 encodes nothing at all.
      expect(
        () =>
            GoogleAuthParser.parseUri('otpauth-migration://offline?data=AAAAA'),
        throwsA(isA<MalformedMigrationUriException>()),
      );
    });

    test('URL-safe base64 (- and _) is accepted', () {
      // 0xFB 0xFF encodes as "+/8" in the standard alphabet and "-_8" in the
      // URL-safe one; both must reach the decoder as the same bytes.
      final payload = encodeMigrationPayload(entries: [_entry()]);
      final urlSafe = base64
          .encode(payload)
          .replaceAll('+', '-')
          .replaceAll('/', '_')
          .replaceAll('=', '');
      final batch = GoogleAuthParser.parseUri(
        'otpauth-migration://offline?data=$urlSafe',
      );
      expect(batch.accounts.single.secret, _vectorASecretB32);
    });

    test('a URI over maxUriLength is refused before anything is decoded', () {
      final huge =
          'otpauth-migration://offline?data='
          '${'A' * (GoogleAuthParser.maxUriLength + 1)}';
      expect(
        () => GoogleAuthParser.parseUri(huge),
        throwsA(isA<MalformedMigrationUriException>()),
      );
    });

    test('a payload over maxPayloadBytes is refused', () {
      expect(
        () => GoogleAuthParser.parsePayload(
          Uint8List(GoogleAuthParser.maxPayloadBytes + 1),
        ),
        throwsA(isA<MalformedMigrationUriException>()),
      );
    });

    test('a structurally broken protobuf body is a FormatException', () {
      // Valid base64, but the bytes are not a parseable message.
      final broken = base64.encode(const [0x0a, 0x40, 0x01]);
      expect(
        () => GoogleAuthParser.parseUri(
          'otpauth-migration://offline?data=${Uri.encodeComponent(broken)}',
        ),
        throwsFormatException,
      );
    });

    test('EVERY truncated prefix of a real payload fails cleanly', () {
      final payload = encodeMigrationPayload(
        entries: [
          _entry(issuer: 'Example'),
          _entry(name: 'bob'),
        ],
        batchSize: 2,
        batchIndex: 1,
        batchId: -2,
      );
      for (var length = 1; length < payload.length; length++) {
        final prefix = Uint8List.sublistView(payload, 0, length);
        try {
          GoogleAuthParser.parsePayload(prefix);
        } on FormatException {
          continue;
        } catch (error) {
          fail('prefix of $length bytes threw ${error.runtimeType}');
        }
      }
    });
  });

  group('batch coordinates', () {
    test('absent batch fields fall back to the proto3 defaults', () {
      final batch = GoogleAuthParser.parsePayload(
        encodeMigrationPayload(
          entries: [_entry()],
          version: null,
          batchSize: null,
          batchIndex: null,
          batchId: null,
        ),
      );
      expect(batch.version, 0);
      expect(batch.batchSize, 0);
      expect(batch.batchIndex, 0);
      expect(batch.batchId, 0);
      expect(batch.accounts, hasLength(1));
    });

    test('an unknown version is reported, never a reason to reject', () {
      final batch = GoogleAuthParser.parsePayload(
        encodeMigrationPayload(entries: [_entry()], version: 99),
      );
      expect(batch.version, 99);
      expect(batch.accounts, hasLength(1));
    });

    test('a repeated scalar takes the last value', () {
      final payload = Uint8List.fromList([
        ...encodeLengthDelimited(1, _entry()),
        ...encodeVarintField(3, 2), // batch_size 2 …
        ...encodeVarintField(3, 5), // … overwritten by 5
      ]);
      expect(GoogleAuthParser.parsePayload(payload).batchSize, 5);
    });

    test('unknown payload fields are skipped, the entries still import', () {
      final payload = Uint8List.fromList([
        ...encodeVarintField(42, 7),
        ...encodeLengthDelimited(1, _entry()),
        ...encodeLengthDelimited(77, const [1, 2, 3]),
        ...encodeVarintField(3, 1),
      ]);
      final batch = GoogleAuthParser.parsePayload(payload);
      expect(batch.accounts, hasLength(1));
      expect(batch.batchSize, 1);
    });

    test('more than maxEntriesPerBatch entries is a FormatException', () {
      final entries = List<Uint8List>.generate(
        GoogleAuthParser.maxEntriesPerBatch + 1,
        (i) => _entry(name: 'user$i@example.com'),
      );
      expect(() => _parse(entries), throwsFormatException);
    });
  });

  group('mapping — algorithm', () {
    test('UNSPECIFIED and SHA1 both map to SHA1', () {
      for (final value in const [
        ProtoAlgorithm.unspecified,
        ProtoAlgorithm.sha1,
      ]) {
        final batch = _parse([_entry(algorithm: value)]);
        expect(
          batch.accounts.single.algorithm,
          OtpAlgorithm.sha1,
          reason: 'algorithm=$value',
        );
      }
    });

    test('SHA256 and SHA512 map through', () {
      expect(
        _parse([
          _entry(algorithm: ProtoAlgorithm.sha256),
        ]).accounts.single.algorithm,
        OtpAlgorithm.sha256,
      );
      expect(
        _parse([
          _entry(algorithm: ProtoAlgorithm.sha512),
        ]).accounts.single.algorithm,
        OtpAlgorithm.sha512,
      );
    });

    test('MD5 is unsupportedType, never downgraded to SHA1', () {
      final skip = _onlySkip(_parse([_entry(algorithm: ProtoAlgorithm.md5)]));
      expect(skip.reason, SkipReason.unsupportedType);
      expect(skip.detail, 'algorithm=MD5');
    });

    test('an algorithm outside the enum is invalidFields', () {
      final skip = _onlySkip(_parse([_entry(algorithm: 9)]));
      expect(skip.reason, SkipReason.invalidFields);
      expect(skip.detail, 'algorithm=9');
    });
  });

  group('mapping — digits', () {
    test('UNSPECIFIED and SIX map to 6, EIGHT maps to 8', () {
      expect(
        _parse([
          _entry(digits: ProtoDigits.unspecified),
        ]).accounts.single.digits,
        6,
      );
      expect(
        _parse([_entry(digits: ProtoDigits.six)]).accounts.single.digits,
        6,
      );
      expect(
        _parse([_entry(digits: ProtoDigits.eight)]).accounts.single.digits,
        8,
      );
    });

    test('a digit count outside the enum is invalidFields', () {
      final skip = _onlySkip(_parse([_entry(digits: 7)]));
      expect(skip.reason, SkipReason.invalidFields);
      expect(skip.detail, 'digits=7');
    });
  });

  group('mapping — type', () {
    test('TOTP maps to totp with the fixed 30-second period', () {
      final account = _parse([_entry(type: ProtoOtpType.totp)]).accounts.single;
      expect(account.type, OtpType.totp);
      expect(account.period, 30);
    });

    test('HOTP with an explicit counter maps to hotp', () {
      final account = _parse([
        _entry(type: ProtoOtpType.hotp, counter: 42),
      ]).accounts.single;
      expect(account.type, OtpType.hotp);
      expect(account.counter, 42);
    });

    test('UNSPECIFIED is unsupportedType — never guessed as TOTP', () {
      final skip = _onlySkip(_parse([_entry(type: ProtoOtpType.unspecified)]));
      expect(skip.reason, SkipReason.unsupportedType);
      expect(skip.detail, 'type=unspecified');
    });

    test('a type outside the enum is unsupportedType', () {
      final skip = _onlySkip(_parse([_entry(type: 5)]));
      expect(skip.reason, SkipReason.unsupportedType);
      expect(skip.detail, 'type=5');
    });

    test('an issuer of "Steam" is NOT promoted to a Steam token', () {
      // Google Authenticator cannot hold a Steam token; promoting one would
      // generate 5-character codes for a service expecting 6 digits.
      final account = _parse([
        _entry(issuer: 'Steam', name: 'gaben'),
      ]).accounts.single;
      expect(account.type, OtpType.totp);
      expect(account.digits, 6);
      expect(account.issuer, 'Steam');
    });
  });

  group('mapping — HOTP counter presence', () {
    test('an absent counter field skips the entry (never defaulted to 0)', () {
      final skip = _onlySkip(
        _parse([_entry(type: ProtoOtpType.hotp, counter: null)]),
      );
      expect(skip.reason, SkipReason.invalidFields);
      expect(skip.detail, 'HOTP entry has no counter');
      expect(skip.label, 'alice@example.com');
    });

    test('an EXPLICIT counter of 0 is honoured — presence, not value', () {
      final absent = encodeOtpParameters(
        secret: fromHex(_vectorASecretHex),
        name: 'alice@example.com',
        algorithm: ProtoAlgorithm.sha1,
        digits: ProtoDigits.six,
        type: ProtoOtpType.hotp,
      );
      final explicitZero = _entry(type: ProtoOtpType.hotp, counter: 0);
      // The two encodings differ by exactly the counter tag.
      expect(explicitZero.length, absent.length + 2);

      final account = _parse([explicitZero]).accounts.single;
      expect(account.type, OtpType.hotp);
      expect(account.counter, 0);
      expect(_parse([absent]).accounts, isEmpty);
    });

    test('a negative counter is invalidFields', () {
      final skip = _onlySkip(
        _parse([_entry(type: ProtoOtpType.hotp, counter: -1)]),
      );
      expect(skip.reason, SkipReason.invalidFields);
      expect(skip.detail, 'counter is negative');
    });

    test('a counter on a TOTP entry is ignored, not carried over', () {
      final account = _parse([
        _entry(type: ProtoOtpType.totp, counter: 99),
      ]).accounts.single;
      expect(account.type, OtpType.totp);
      expect(account.counter, 0);
    });
  });

  group('mapping — name and issuer', () {
    test('the issuer field wins over the one embedded in the label', () {
      final account = _parse([
        _entry(name: 'Label:alice', issuer: 'Field'),
      ]).accounts.single;
      expect(account.issuer, 'Field');
      expect(account.accountName, 'alice');
    });

    test('with no issuer field, the label prefix is used', () {
      final account = _parse([_entry(name: 'GitHub:alice')]).accounts.single;
      expect(account.issuer, 'GitHub');
      expect(account.accountName, 'alice');
    });

    test('only the FIRST colon splits the label', () {
      final account = _parse([_entry(name: 'GitHub:a:b')]).accounts.single;
      expect(account.issuer, 'GitHub');
      expect(account.accountName, 'a:b');
    });

    test('a name without a colon is entirely the account name', () {
      final account = _parse([
        _entry(name: 'alice@example.com'),
      ]).accounts.single;
      expect(account.issuer, isNull);
      expect(account.accountName, 'alice@example.com');
    });

    test('surrounding whitespace is trimmed off both halves', () {
      final account = _parse([
        _entry(name: '  GitHub :  alice  '),
      ]).accounts.single;
      expect(account.issuer, 'GitHub');
      expect(account.accountName, 'alice');
    });

    test('an empty name falls back to the issuer', () {
      final account = _parse([
        _entry(name: '', issuer: 'GitHub'),
      ]).accounts.single;
      expect(account.issuer, 'GitHub');
      expect(account.accountName, 'GitHub');
    });

    test('an entry with neither name nor issuer gets the placeholder', () {
      final account = _parse([
        _entry(name: null, issuer: null),
      ]).accounts.single;
      expect(account.issuer, isNull);
      expect(account.accountName, '(isimsiz)');
    });

    test('a blank issuer field falls through to the label issuer', () {
      final account = _parse([
        _entry(name: 'GitHub:alice', issuer: '   '),
      ]).accounts.single;
      expect(account.issuer, 'GitHub');
    });

    test('a skipped entry is labelled "Issuer (account)"', () {
      final skip = _onlySkip(
        _parse([_entry(issuer: 'Example', name: 'alice', digits: 7)]),
      );
      expect(skip.label, 'Example (alice)');
    });
  });

  group('mapping — secret', () {
    test('an absent secret field is invalidSecret', () {
      final entry = encodeOtpParameters(
        name: 'alice',
        algorithm: ProtoAlgorithm.sha1,
        digits: ProtoDigits.six,
        type: ProtoOtpType.totp,
      );
      final skip = _onlySkip(_parse([entry]));
      expect(skip.reason, SkipReason.invalidSecret);
      expect(skip.detail, 'secret missing or empty');
    });

    test('a zero-length secret is invalidSecret', () {
      final skip = _onlySkip(_parse([_entry(secret: const <int>[])]));
      expect(skip.reason, SkipReason.invalidSecret);
    });

    test('raw bytes are Base32-ENCODED, never decoded', () {
      // Bytes that are not valid Base32 text still produce a usable secret,
      // because the payload carries bytes and we encode them.
      final secret = List<int>.generate(20, (i) => (i * 37) & 0xFF);
      final account = _parse([_entry(secret: secret)]).accounts.single;
      expect(account.secret, Base32.encode(secret));
      expect(account.secretBytes, orderedEquals(secret));
    });

    test('a secret over maxSecretBytes is a FormatException', () {
      expect(
        () => _parse([_entry(secret: List<int>.filled(2000, 0x41))]),
        throwsFormatException,
      );
      // The limit itself is fine.
      expect(
        _parse([
          _entry(secret: List<int>.filled(ProtobufLimits.maxSecretBytes, 0x41)),
        ]).accounts,
        hasLength(1),
      );
    });
  });

  group('malformed text fields', () {
    test(
      'a non-UTF-8 name drops ONE entry, the rest of the QR still imports',
      () {
        // 0xFF/0xFE/0xFD are byte values that never appear in valid UTF-8, so
        // this is written at the wire level rather than through the encoder's
        // `String` API.
        final withBadName = Uint8List.fromList([
          ...encodeLengthDelimited(1, fromHex(_vectorASecretHex)),
          ...encodeLengthDelimited(2, const [0xFF, 0xFE, 0xFD]),
          ...encodeVarintField(4, ProtoAlgorithm.sha1),
          ...encodeVarintField(5, ProtoDigits.six),
          ...encodeVarintField(6, ProtoOtpType.totp),
        ]);

        final batch = _parse([withBadName, _entry(name: 'good')]);
        expect(batch.accounts, hasLength(1));
        expect(batch.accounts.single.accountName, 'good');
        expect(batch.skipped, hasLength(1));
        expect(batch.skipped.single.reason, SkipReason.invalidFields);
        expect(batch.skipped.single.detail, 'entry has a non-UTF-8 text field');
        expect(batch.skipped.single.label, isNull);
      },
    );

    test('a text field over maxStringBytes is a FormatException', () {
      expect(
        () => _parse([_entry(name: 'a' * (ProtobufLimits.maxStringBytes + 1))]),
        throwsFormatException,
      );
    });

    test('a wrongly typed field is skipped instead of misread', () {
      // `name` written as a varint rather than a string: the field is ignored
      // and the entry still imports under the placeholder name.
      final entry = Uint8List.fromList([
        ...encodeLengthDelimited(1, fromHex(_vectorASecretHex)),
        ...encodeVarintField(2, 12345),
        ...encodeVarintField(4, ProtoAlgorithm.sha1),
        ...encodeVarintField(5, ProtoDigits.six),
        ...encodeVarintField(6, ProtoOtpType.totp),
      ]);
      final account = _parse([entry]).accounts.single;
      expect(account.accountName, '(isimsiz)');
    });

    test('unknown entry fields are skipped', () {
      final entry = Uint8List.fromList([
        ..._entry(name: 'alice'),
        ...encodeVarintField(20, 1),
        ...encodeLengthDelimited(21, const [9, 9]),
      ]);
      expect(_parse([entry]).accounts.single.accountName, 'alice');
    });
  });

  group('SECURITY — no secret ever escapes', () {
    test('no SkippedEntry mentions the secret, in any form', () {
      // One entry per rejection path, all sharing a recognizable secret.
      final secret = fromHex('deadbeefdeadbeefdead');
      final base32 = Base32.encode(secret);
      final hex = toHex(secret);
      final b64 = base64.encode(secret);

      final batch = _parse([
        _entry(secret: secret, algorithm: ProtoAlgorithm.md5),
        _entry(secret: secret, algorithm: 9),
        _entry(secret: secret, digits: 7),
        _entry(secret: secret, type: ProtoOtpType.unspecified),
        _entry(secret: secret, type: ProtoOtpType.hotp, counter: null),
        _entry(secret: secret, type: ProtoOtpType.hotp, counter: -1),
      ]);
      expect(batch.accounts, isEmpty);
      expect(batch.skipped, hasLength(6));

      for (final skip in batch.skipped) {
        final text = '${skip.label} ${skip.detail}';
        expect(text, isNot(contains(base32)));
        expect(text, isNot(contains(hex)));
        expect(text, isNot(contains(b64)));
        // Not even a fragment: eight Base32 characters is already half a seed.
        expect(text, isNot(contains(base32.substring(0, 8))));
      }
    });

    test('no exception message quotes the payload or the raw URI', () {
      final secret = fromHex('deadbeefdeadbeefdead');
      final payload = encodeMigrationPayload(entries: [_entry(secret: secret)]);
      final b64 = base64.encode(payload);

      // Corrupt the base64 so decoding fails while the secret is still in it.
      final corrupted =
          'otpauth-migration://offline?data='
          '${Uri.encodeComponent('$b64*')}';
      Object? thrown;
      try {
        GoogleAuthParser.parseUri(corrupted);
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      final message = thrown.toString();
      expect(message, isNot(contains(b64.substring(0, 12))));
      expect(message, isNot(contains(Base32.encode(secret))));
    });

    test('a structural FormatException names offsets, not bytes', () {
      final secret = fromHex('deadbeefdeadbeefdead');
      final payload = encodeMigrationPayload(entries: [_entry(secret: secret)]);
      final truncated = Uint8List.sublistView(payload, 0, payload.length - 3);
      Object? thrown;
      try {
        GoogleAuthParser.parsePayload(truncated);
        fail('a truncated payload must not parse');
      } on FormatException catch (error) {
        thrown = error;
      }
      expect(thrown.toString(), isNot(contains('deadbeef')));
      expect(thrown.toString(), isNot(contains(Base32.encode(secret))));
    });
  });

  group('round trip', () {
    test('20 pseudo-random entries survive encode → URI → parse unchanged', () {
      // Deterministic generator: a failure is reproducible.
      var state = 0x13579BDF;
      int next(int bound) {
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
        return (state >> 8) % bound;
      }

      final expected = <OtpAccount>[];
      final entries = <Uint8List>[];
      for (var i = 0; i < 20; i++) {
        final secret = List<int>.generate(10 + next(23), (_) => next(256));
        final isHotp = next(2) == 0;
        final algorithmIndex = next(3); // sha1 / sha256 / sha512
        final eightDigits = next(2) == 0;
        final counter = next(100000);
        final issuer = next(3) == 0 ? null : 'Issuer$i';
        final name = 'user$i@example.com';

        entries.add(
          encodeOtpParameters(
            secret: secret,
            name: name,
            issuer: issuer,
            algorithm: algorithmIndex + 1,
            digits: eightDigits ? ProtoDigits.eight : ProtoDigits.six,
            type: isHotp ? ProtoOtpType.hotp : ProtoOtpType.totp,
            counter: isHotp ? counter : null,
          ),
        );
        expected.add(
          OtpAccount(
            secret: Base32.encode(secret),
            type: isHotp ? OtpType.hotp : OtpType.totp,
            issuer: issuer,
            accountName: name,
            algorithm: OtpAlgorithm.values[algorithmIndex],
            digits: eightDigits ? 8 : 6,
            period: 30,
            counter: isHotp ? counter : 0,
          ),
        );
      }

      final uri = migrationUri(
        encodeMigrationPayload(
          entries: entries,
          batchSize: 1,
          batchIndex: 0,
          batchId: -7,
        ),
      );
      final batch = GoogleAuthParser.parseUri(uri);

      expect(batch.skipped, isEmpty);
      expect(batch.batchId, -7);
      expect(batch.accounts, hasLength(20));
      for (var i = 0; i < 20; i++) {
        final actual = batch.accounts[i];
        final want = expected[i];
        expect(actual.secret, want.secret, reason: 'entry $i secret');
        expect(actual.type, want.type, reason: 'entry $i type');
        expect(actual.issuer, want.issuer, reason: 'entry $i issuer');
        expect(actual.accountName, want.accountName, reason: 'entry $i name');
        expect(actual.algorithm, want.algorithm, reason: 'entry $i algorithm');
        expect(actual.digits, want.digits, reason: 'entry $i digits');
        expect(actual.period, 30, reason: 'entry $i period');
        expect(actual.counter, want.counter, reason: 'entry $i counter');
      }
    });

    test('accounts keep the payload order, and each gets a fresh id', () {
      final batch = _parse([
        _entry(name: 'first'),
        _entry(name: 'second'),
        _entry(name: 'third'),
      ]);
      expect(
        batch.accounts.map((a) => a.accountName),
        orderedEquals(const ['first', 'second', 'third']),
      );
      expect(batch.accounts.map((a) => a.id).toSet(), hasLength(3));
    });
  });
}
