/// Test-only protobuf **encoder** — the mirror image of
/// `lib/features/import_export/data/protobuf_wire.dart` (plan §1).
///
/// WHY IT EXISTS: no real Google Authenticator export may enter this repository
/// (it would be a committed bundle of live secrets), so every migration fixture
/// is synthesized here. Writing the encoder by hand also means the decoder is
/// never checked against itself: the plan's golden vectors were derived
/// independently, and `protobuf_wire_test` compares this encoder's output
/// against those fixed hex strings byte for byte before any decode is trusted.
///
/// Pure Dart, no Flutter, no `protobuf` package — matching the production side.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Base-128 varint of [value], interpreted as a 64-bit two's-complement
/// integer. A negative value therefore sign-extends to the full 10 bytes,
/// exactly as proto3 encodes a negative `int32` such as `batch_id`.
Uint8List encodeVarint(int value) {
  final out = <int>[];
  var v = value;
  if (v < 0) {
    // Emit the 64-bit two's-complement pattern: nine 7-bit groups taken with a
    // logical shift, then the remaining sign bit. `>>>` is the unsigned shift,
    // so this does not stop early on a negative.
    for (var i = 0; i < 9; i++) {
      out.add((v & 0x7F) | 0x80);
      v = v >>> 7;
    }
    out.add(v & 0x7F);
    return Uint8List.fromList(out);
  }
  while (true) {
    final b = v & 0x7F;
    v = v >>> 7;
    if (v == 0) {
      out.add(b);
      break;
    }
    out.add(b | 0x80);
  }
  return Uint8List.fromList(out);
}

/// Tag byte group for [field] with [wireType] (`field << 3 | wireType`).
Uint8List encodeTag(int field, int wireType) =>
    encodeVarint((field << 3) | wireType);

/// A complete length-delimited (wire type 2) field: tag, length, payload.
Uint8List encodeLengthDelimited(int field, List<int> payload) =>
    _concat([encodeTag(field, 2), encodeVarint(payload.length), payload]);

/// A complete varint (wire type 0) field.
Uint8List encodeVarintField(int field, int value) =>
    _concat([encodeTag(field, 0), encodeVarint(value)]);

/// A complete 32-bit (wire type 5) field, little-endian.
Uint8List encodeFixed32Field(int field, int value) {
  final data = Uint8List(4);
  ByteData.sublistView(data).setUint32(0, value, Endian.little);
  return _concat([encodeTag(field, 5), data]);
}

/// A complete 64-bit (wire type 1) field, little-endian.
Uint8List encodeFixed64Field(int field, int value) {
  final data = Uint8List(8);
  ByteData.sublistView(data).setInt64(0, value, Endian.little);
  return _concat([encodeTag(field, 1), data]);
}

/// Google's `Algorithm` enum (plan §0).
abstract final class ProtoAlgorithm {
  static const int unspecified = 0;
  static const int sha1 = 1;
  static const int sha256 = 2;
  static const int sha512 = 3;
  static const int md5 = 4;
}

/// Google's `DigitCount` enum (plan §0).
abstract final class ProtoDigits {
  static const int unspecified = 0;
  static const int six = 1;
  static const int eight = 2;
}

/// Google's `OtpType` enum (plan §0).
abstract final class ProtoOtpType {
  static const int unspecified = 0;
  static const int hotp = 1;
  static const int totp = 2;
}

/// One `OtpParameters` sub-message.
///
/// Every field is optional so a test can express *absence* — which is the whole
/// point for `counter`: passing `null` omits the tag (proto3 "no presence"),
/// passing `0` writes an explicit zero. Fields are emitted in ascending field
/// number, the canonical order Google's exporter uses.
Uint8List encodeOtpParameters({
  List<int>? secret,
  String? name,
  String? issuer,
  int? algorithm,
  int? digits,
  int? type,
  int? counter,
}) => _concat([
  if (secret != null) encodeLengthDelimited(1, secret),
  if (name != null) encodeLengthDelimited(2, utf8.encode(name)),
  if (issuer != null) encodeLengthDelimited(3, utf8.encode(issuer)),
  if (algorithm != null) encodeVarintField(4, algorithm),
  if (digits != null) encodeVarintField(5, digits),
  if (type != null) encodeVarintField(6, type),
  if (counter != null) encodeVarintField(7, counter),
]);

/// A whole `MigrationPayload`: the [entries] (already-encoded `OtpParameters`
/// bodies) followed by the batch coordinates.
///
/// Batch fields default to a single-code export. Any of them may be `null` to
/// omit the tag entirely, which is how the "field absent → proto3 default"
/// paths are exercised.
Uint8List encodeMigrationPayload({
  List<List<int>> entries = const <List<int>>[],
  int? version = 1,
  int? batchSize = 1,
  int? batchIndex = 0,
  int? batchId = 0,
}) => _concat([
  for (final entry in entries) encodeLengthDelimited(1, entry),
  if (version != null) encodeVarintField(2, version),
  if (batchSize != null) encodeVarintField(3, batchSize),
  if (batchIndex != null) encodeVarintField(4, batchIndex),
  if (batchId != null) encodeVarintField(5, batchId),
]);

/// `otpauth-migration://offline?data=…` around [payload].
///
/// [percentEncode] false leaves the standard-alphabet base64 verbatim (`+`, `/`
/// and `=` raw in the query, which is what several QR generators emit);
/// true percent-encodes every reserved character. Both must decode identically
/// — that is the `Uri.queryParameters` trap this parser exists to avoid.
String migrationUri(List<int> payload, {bool percentEncode = true}) {
  final b64 = base64.encode(payload);
  final data = percentEncode ? Uri.encodeComponent(b64) : b64;
  return 'otpauth-migration://offline?data=$data';
}

/// Lowercase hex of [bytes], for byte-exact comparison against the plan's
/// golden vectors.
String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Bytes of a lowercase/uppercase hex string.
Uint8List fromHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Uint8List _concat(List<List<int>> parts) {
  var length = 0;
  for (final part in parts) {
    length += part.length;
  }
  final out = Uint8List(length);
  var offset = 0;
  for (final part in parts) {
    out.setRange(offset, offset + part.length, part);
    offset += part.length;
  }
  return out;
}
