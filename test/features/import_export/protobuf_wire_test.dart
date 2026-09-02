/// Phase 5 Patch 2 — the hand-written protobuf wire reader (plan §1).
///
/// Two jobs. First, prove the test-only encoder in `test/support/
/// protobuf_encoder.dart` agrees byte for byte with the plan's independently
/// derived golden vectors — without that, every later "decoder matches
/// encoder" assertion would only prove the two halves share a bug. Second,
/// cover the reader's failure surface: truncation, oversized varints, group
/// wire types and unknown fields, none of which may crash, hang or leak a
/// payload byte into an exception message.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/features/import_export/data/protobuf_wire.dart';

import '../../support/protobuf_encoder.dart';

/// Plan §1, vector A — a single TOTP entry, batch 1/1, `batch_id` 0.
const String _goldenAEntryHex =
    '0a0a48656c6c6f21deadbeef1211616c696365406578616d706c652e636f6d'
    '1a074578616d706c65200128013002';
const String _goldenAPayloadHex =
    '0a2e0a0a48656c6c6f21deadbeef1211616c696365406578616d706c652e636f6d'
    '1a074578616d706c652001280130021001180120002800';

/// Plan §1, vector B — `batch_id` -2, which proto3 sign-extends to a full
/// 10-byte varint (`28 fe ff ff ff ff ff ff ff ff 01`).
const String _goldenBPayloadHex =
    '0a170a0a3e3ffbefbefa001122331203626f62200128013002'
    '10011801200028feffffffffffffffff01';

Uint8List _goldenAEntry() => encodeOtpParameters(
  secret: fromHex('48656c6c6f21deadbeef'),
  name: 'alice@example.com',
  issuer: 'Example',
  algorithm: ProtoAlgorithm.sha1,
  digits: ProtoDigits.six,
  type: ProtoOtpType.totp,
);

Uint8List _goldenBEntry() => encodeOtpParameters(
  secret: fromHex('3e3ffbefbefa00112233'),
  name: 'bob',
  algorithm: ProtoAlgorithm.sha1,
  digits: ProtoDigits.six,
  type: ProtoOtpType.totp,
);

/// Reads every field of [bytes] and returns them as `field:wireType` pairs,
/// skipping anything it does not need. Exercises the reader end to end.
List<String> _drain(Uint8List bytes) {
  final reader = ProtobufReader(bytes);
  final seen = <String>[];
  while (reader.hasMore) {
    final tag = reader.readTag();
    seen.add('${tag.field}:${tag.wireType}');
    reader.skipField(tag.wireType);
  }
  return seen;
}

void main() {
  group('golden vectors — encoder vs. the plan, byte for byte', () {
    test('vector A OtpParameters matches the plan hex exactly', () {
      expect(toHex(_goldenAEntry()), _goldenAEntryHex);
    });

    test('vector A MigrationPayload matches the plan hex exactly', () {
      final payload = encodeMigrationPayload(
        entries: [_goldenAEntry()],
        version: 1,
        batchSize: 1,
        batchIndex: 0,
        batchId: 0,
      );
      expect(toHex(payload), _goldenAPayloadHex);
    });

    test('vector A base64 and URI match the plan', () {
      final payload = encodeMigrationPayload(entries: [_goldenAEntry()]);
      expect(
        migrationUri(payload, percentEncode: false),
        'otpauth-migration://offline?data='
        'Ci4KCkhlbGxvId6tvu8SEWFsaWNlQGV4YW1wbGUuY29tGgdFeGFtcGxlIAEoATACEAEYASAAKAA=',
      );
      expect(
        migrationUri(payload),
        'otpauth-migration://offline?data='
        'Ci4KCkhlbGxvId6tvu8SEWFsaWNlQGV4YW1wbGUuY29tGgdFeGFtcGxlIAEoATACEAEYASAAKAA%3D',
      );
    });

    test(
      'vector B MigrationPayload (negative batch_id) matches the plan hex',
      () {
        final payload = encodeMigrationPayload(
          entries: [_goldenBEntry()],
          version: 1,
          batchSize: 1,
          batchIndex: 0,
          batchId: -2,
        );
        expect(toHex(payload), _goldenBPayloadHex);
      },
    );

    test(
      'vector B base64 carries the "+" and "/" that break queryParameters',
      () {
        final b64 = migrationUri(
          encodeMigrationPayload(entries: [_goldenBEntry()], batchId: -2),
          percentEncode: false,
        );
        expect(b64.contains('+'), isTrue);
        expect(b64.contains('/'), isTrue);
      },
    );
  });

  group('readVarint', () {
    test('a 1-byte varint', () {
      expect(ProtobufReader(encodeVarint(1)).readVarint(), 1);
      expect(ProtobufReader(encodeVarint(0)).readVarint(), 0);
      expect(ProtobufReader(encodeVarint(127)).readVarint(), 127);
    });

    test('a 2-byte varint', () {
      final bytes = encodeVarint(300);
      expect(bytes.length, 2);
      expect(ProtobufReader(bytes).readVarint(), 300);
    });

    test('a 5-byte varint (max int32)', () {
      final bytes = encodeVarint(0x7FFFFFFF);
      expect(bytes.length, 5);
      expect(ProtobufReader(bytes).readVarint(), 0x7FFFFFFF);
    });

    test('a 10-byte varint round-trips -2 as a signed 64-bit value', () {
      final bytes = encodeVarint(-2);
      expect(bytes.length, ProtobufLimits.maxVarintBytes);
      expect(toHex(bytes), 'feffffffffffffffff01');
      expect(ProtobufReader(bytes).readVarint(), -2);
    });

    test('every negative int32 round-trips', () {
      for (final value in const [-1, -2, -128, -2147483648, -1234567]) {
        expect(
          ProtobufReader(encodeVarint(value)).readVarint(),
          value,
          reason: 'varint $value',
        );
      }
    });

    test('a non-canonical 10-byte varint is rejected', () {
      // Ten bytes is the maximum, and on the tenth `shift` is 63 → only bit 63
      // can legally be contributed, so its payload must be 0x00 or 0x01.
      // 0x7F there is protobuf-illegal and would otherwise wrap silently.
      final bytes = Uint8List.fromList([
        ...List<int>.filled(ProtobufLimits.maxVarintBytes - 1, 0x80),
        0x7F,
      ]);
      expect(() => ProtobufReader(bytes).readVarint(), throwsFormatException);
    });

    test('the tenth byte may still be 0x00 or 0x01', () {
      for (final last in const [0x00, 0x01]) {
        final bytes = Uint8List.fromList([
          ...List<int>.filled(ProtobufLimits.maxVarintBytes - 1, 0x80),
          last,
        ]);
        expect(
          ProtobufReader(bytes).readVarint(),
          last == 0 ? 0 : 1 << 63,
          reason: 'tenth byte 0x${last.toRadixString(16)}',
        );
      }
    });

    test('an 11-byte varint is rejected', () {
      // Eleven continuation bytes: the reader must stop at ten, not keep going.
      final bytes = Uint8List.fromList([
        ...List<int>.filled(ProtobufLimits.maxVarintBytes, 0xFF),
        0x01,
      ]);
      expect(() => ProtobufReader(bytes).readVarint(), throwsFormatException);
    });

    test('a varint of nothing but continuation bytes is rejected', () {
      final bytes = Uint8List.fromList(List<int>.filled(16, 0x80));
      expect(() => ProtobufReader(bytes).readVarint(), throwsFormatException);
    });

    test('a truncated varint throws instead of returning a partial value', () {
      final bytes = Uint8List.fromList([
        0xAC,
      ]); // continuation set, no next byte
      expect(() => ProtobufReader(bytes).readVarint(), throwsFormatException);
    });

    test('an empty buffer has nothing to read', () {
      final reader = ProtobufReader(Uint8List(0));
      expect(reader.hasMore, isFalse);
      expect(reader.readVarint, throwsFormatException);
    });
  });

  group('readTag', () {
    test('splits field number and wire type', () {
      final tag = ProtobufReader(encodeTag(5, 2)).readTag();
      expect(tag.field, 5);
      expect(tag.wireType, 2);
    });

    test('field number 0 is illegal', () {
      // Tag 0x00 → field 0, wire type 0.
      expect(
        () => ProtobufReader(Uint8List.fromList([0x00])).readTag(),
        throwsFormatException,
      );
      // Tag 0x02 → field 0, wire type 2 (a plausible-looking prefix).
      expect(
        () => ProtobufReader(Uint8List.fromList([0x02, 0x00])).readTag(),
        throwsFormatException,
      );
    });

    test('a tag wider than 32 bits is rejected, not silently truncated', () {
      expect(
        () => ProtobufReader(encodeVarint(-1)).readTag(),
        throwsFormatException,
      );
    });
  });

  group('readLengthDelimited', () {
    test('returns a view, not a copy', () {
      final payload = encodeLengthDelimited(1, const [1, 2, 3]);
      final reader = ProtobufReader(payload);
      reader.readTag();
      final view = reader.readLengthDelimited();
      expect(view, orderedEquals(const [1, 2, 3]));
      // A view shares the backing store: mutating it is visible in the source.
      view[0] = 9;
      expect(payload[2], 9);
    });

    test('a zero-length field is legal', () {
      final reader = ProtobufReader(encodeLengthDelimited(1, const <int>[]));
      reader.readTag();
      expect(reader.readLengthDelimited(), isEmpty);
      expect(reader.hasMore, isFalse);
    });

    test('a length running past the end is rejected', () {
      // Tag 0x0a (field 1, wire 2), length 100, but only 2 bytes follow.
      final bytes = Uint8List.fromList([0x0a, 100, 1, 2]);
      final reader = ProtobufReader(bytes);
      reader.readTag();
      expect(reader.readLengthDelimited, throwsFormatException);
    });

    test('a negative (sign-extended) length is rejected', () {
      final bytes = Uint8List.fromList([0x0a, ...encodeVarint(-1), 1, 2, 3]);
      final reader = ProtobufReader(bytes);
      reader.readTag();
      expect(reader.readLengthDelimited, throwsFormatException);
    });

    test('an end argument scopes the reader without copying', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final reader = ProtobufReader(bytes, end: 2);
      expect(reader.readVarint(), 1);
      expect(reader.readVarint(), 2);
      expect(reader.hasMore, isFalse);
    });

    test('an end past the buffer is rejected at construction', () {
      expect(() => ProtobufReader(Uint8List(2), end: 5), throwsFormatException);
      expect(
        () => ProtobufReader(Uint8List(2), end: -1),
        throwsFormatException,
      );
    });
  });

  group('skipField', () {
    test('skips varint, 64-bit, length-delimited and 32-bit fields', () {
      final bytes = _concatBytes([
        encodeVarintField(1, 300),
        encodeFixed64Field(2, -5),
        encodeLengthDelimited(3, const [7, 7, 7]),
        encodeFixed32Field(4, 42),
        encodeVarintField(5, 1),
      ]);
      expect(_drain(bytes), ['1:0', '2:1', '3:2', '4:5', '5:0']);
    });

    test('group wire types 3 and 4 are rejected, never skipped', () {
      for (final wireType in const [3, 4]) {
        final reader = ProtobufReader(encodeTag(1, wireType));
        final tag = reader.readTag();
        expect(
          () => reader.skipField(tag.wireType),
          throwsFormatException,
          reason: 'wire type $wireType',
        );
      }
    });

    test('wire types 6 and 7 do not exist and are rejected', () {
      for (final wireType in const [6, 7]) {
        expect(
          () => ProtobufReader(Uint8List(0)).skipField(wireType),
          throwsFormatException,
          reason: 'wire type $wireType',
        );
      }
    });

    test('a truncated fixed-width field is rejected', () {
      // Tag for a 32-bit field, then only 2 of the 4 bytes.
      final bytes = Uint8List.fromList([0x0d, 1, 2]);
      final reader = ProtobufReader(bytes);
      final tag = reader.readTag();
      expect(() => reader.skipField(tag.wireType), throwsFormatException);
    });
  });

  group('unknown fields and truncation', () {
    test('an unknown high field number is just another skippable field', () {
      final bytes = _concatBytes([
        encodeVarintField(1, 1),
        encodeLengthDelimited(99, const [1, 2, 3, 4]),
        encodeVarintField(2, 2),
      ]);
      expect(_drain(bytes), ['1:0', '99:2', '2:0']);
    });

    test(
      'EVERY truncated prefix of a real payload throws — never a hang, never '
      'a crash',
      () {
        final payload = encodeMigrationPayload(
          entries: [_goldenAEntry(), _goldenBEntry()],
          batchSize: 2,
          batchIndex: 1,
          batchId: -2,
        );
        for (var length = 1; length < payload.length; length++) {
          final prefix = Uint8List.sublistView(payload, 0, length);
          try {
            // The full drain either consumes the prefix cleanly (a prefix can
            // land exactly on a field boundary) or fails with FormatException.
            // What it must never do is throw anything else or loop forever.
            _drain(prefix);
          } on FormatException {
            continue;
          } catch (error) {
            fail(
              'prefix of $length bytes threw ${error.runtimeType}, '
              'expected FormatException',
            );
          }
        }
      },
    );

    test(
      'a fuzz sweep of random bytes only ever fails with FormatException',
      () {
        // Deterministic pseudo-random bytes: no seed drift between CI runs.
        var state = 0x2545F491;
        int next() {
          state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
          return (state >> 16) & 0xFF;
        }

        for (var round = 0; round < 200; round++) {
          final bytes = Uint8List.fromList(
            List<int>.generate(1 + round % 40, (_) => next()),
          );
          try {
            _drain(bytes);
          } on FormatException {
            continue;
          } catch (error) {
            fail(
              'round $round threw ${error.runtimeType}, '
              'expected FormatException',
            );
          }
        }
      },
    );
  });

  group('limits', () {
    test('the declared ceilings are the ones the plan fixed', () {
      expect(ProtobufLimits.maxVarintBytes, 10);
      expect(ProtobufLimits.maxPayloadBytes, 64 * 1024);
      expect(ProtobufLimits.maxEntriesPerBatch, 256);
      expect(ProtobufLimits.maxSecretBytes, 1024);
      expect(ProtobufLimits.maxStringBytes, 512);
    });
  });
}

Uint8List _concatBytes(List<List<int>> parts) {
  final out = <int>[];
  for (final part in parts) {
    out.addAll(part);
  }
  return Uint8List.fromList(out);
}
