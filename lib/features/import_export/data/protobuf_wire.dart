/// Minimal hand-written protobuf wire reader — just enough for Google
/// Authenticator's `MigrationPayload` (plan §1).
///
/// No codegen and no `protobuf` package on purpose: the project carries no
/// generated code anywhere, and proto3 field *presence* for the HOTP `counter`
/// (absent vs. explicit 0) is only observable with a reader that reports which
/// tags actually appeared — a generated message would hand us a default 0 and
/// we would silently desynchronize the token.
///
/// Pure Dart: no Flutter, no IO, no plugins, so it runs on the host VM and
/// inside `Isolate.run`.
///
/// Varints are decoded into Dart's native 64-bit two's-complement `int`, which
/// is what makes a sign-extended negative `batch_id` (10 bytes, bit 63 set)
/// come back as the negative number Google wrote. This reader is consequently
/// VM/AOT only — the app has no web target.
///
/// SECURITY: every byte that flows through here is secret material. Exception
/// messages describe the *structure* that failed (offset, tag, length) and must
/// never quote a value, a decoded string or a secret byte.
library;

import 'dart:typed_data';

/// Hard ceilings shared by the wire reader and its callers
/// (`GoogleAuthParser`). Every one of them turns into a `FormatException`
/// rather than a best-effort parse: an oversized or malformed migration blob is
/// hostile input, not a token worth rescuing.
abstract final class ProtobufLimits {
  /// Longest varint accepted (64-bit value + continuation bits). `batch_id` is
  /// a signed `int32` that Google may write negative, which proto3 encodes as a
  /// sign-extended 10-byte varint — so 10 is a requirement, not slack.
  static const int maxVarintBytes = 10;

  /// Largest decoded payload (64 KiB). Checked *before* base64-decoding, from
  /// the encoded length, so a huge QR never reaches the heap as bytes.
  static const int maxPayloadBytes = 64 * 1024;

  /// Most `OtpParameters` entries accepted in a single batch. Google caps a QR
  /// far below this; anything larger is a crafted payload.
  static const int maxEntriesPerBatch = 256;

  /// Longest `secret` field. A real OTP secret is 10–32 bytes.
  static const int maxSecretBytes = 1024;

  /// Longest UTF-8 `name` / `issuer` field.
  static const int maxStringBytes = 512;
}

/// Forward-only cursor over a protobuf wire buffer.
///
/// Deliberately not recursive: `MigrationPayload` nests exactly one level
/// (`OtpParameters`), and the caller decodes that level by constructing a
/// second reader over the sub-range returned by [readLengthDelimited]. There is
/// therefore no depth to blow a stack with.
class ProtobufReader {
  final Uint8List _bytes;
  final int _end;
  int _pos = 0;

  /// Reads [bytes] from offset 0 up to [end] (defaults to `bytes.length`).
  /// [end] lets a caller scope a reader to a nested message without copying.
  ProtobufReader(Uint8List bytes, {int? end})
      : _bytes = bytes,
        _end = end ?? bytes.length {
    if (_end < 0 || _end > _bytes.length) {
      throw FormatException(
          'protobuf: end $_end outside buffer of ${_bytes.length} bytes');
    }
  }

  /// Whether any unread byte remains before the end of this reader's range.
  bool get hasMore => _pos < _end;

  /// Reads a tag byte group. Field number 0 is illegal in protobuf →
  /// `FormatException`.
  ({int field, int wireType}) readTag() {
    final tag = readVarint();
    // A tag is a 32-bit unsigned value; anything wider (or sign-extended
    // negative) is corruption, and `tag >> 3` on a negative would hand back a
    // nonsense field number instead of failing.
    if (tag < 0 || tag > 0xFFFFFFFF) {
      throw FormatException('protobuf: tag out of range before offset $_pos');
    }
    final field = tag >> 3;
    if (field == 0) {
      throw FormatException(
          'protobuf: field number 0 is illegal before offset $_pos');
    }
    return (field: field, wireType: tag & 0x07);
  }

  /// Reads a base-128 varint as a 64-bit signed value. More than
  /// [ProtobufLimits.maxVarintBytes] bytes, or a truncated buffer →
  /// `FormatException`.
  int readVarint() {
    var result = 0;
    var shift = 0;
    for (var i = 0; i < ProtobufLimits.maxVarintBytes; i++) {
      if (_pos >= _end) {
        throw FormatException('protobuf: truncated varint at offset $_pos');
      }
      final byte = _bytes[_pos++];
      // On the 10th byte `shift` is 63, so only bit 63 (the sign bit) can be
      // contributed — exactly how proto3 sign-extends a negative int32. Which
      // is also why its payload bits may only be 0x00 or 0x01: protobuf calls
      // anything else a non-canonical varint, and shifting those extra bits by
      // 63 would silently wrap into a *different* value instead of failing.
      // Golden vector B's `…ff01` ends in 0x01 and is unaffected.
      if (i == ProtobufLimits.maxVarintBytes - 1 && (byte & 0x7F) > 0x01) {
        throw FormatException(
            'protobuf: non-canonical 10-byte varint at offset ${_pos - 1}');
      }
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
    }
    throw FormatException(
        'protobuf: varint longer than ${ProtobufLimits.maxVarintBytes} bytes '
        'at offset $_pos');
  }

  /// Reads a length-delimited field and returns a **view** onto the backing
  /// buffer (`Uint8List.sublistView`, no copy). A negative length or one that
  /// runs past the end of the range → `FormatException`.
  Uint8List readLengthDelimited() {
    final length = readVarint();
    if (length < 0) {
      throw FormatException(
          'protobuf: negative length-delimited size at offset $_pos');
    }
    if (length > _end - _pos) {
      throw FormatException(
          'protobuf: length $length runs past the end of the message '
          '(${_end - _pos} bytes left at offset $_pos)');
    }
    final view = Uint8List.sublistView(_bytes, _pos, _pos + length);
    _pos += length;
    return view;
  }

  /// Skips an unknown field of [wireType]. Supports 0 (varint), 1 (64-bit),
  /// 2 (length-delimited) and 5 (32-bit); the deprecated group types 3 and 4
  /// are rejected with `FormatException` instead of being skipped, because
  /// their end is only findable by recursive scanning.
  void skipField(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
      case 1:
        _skip(8);
      case 2:
        readLengthDelimited();
      case 5:
        _skip(4);
      case 3:
      case 4:
        throw FormatException(
            'protobuf: group wire type $wireType is not supported '
            '(offset $_pos)');
      default:
        throw FormatException(
            'protobuf: unknown wire type $wireType at offset $_pos');
    }
  }

  /// Advances past [count] fixed-width bytes, or fails if they are not there.
  void _skip(int count) {
    if (count > _end - _pos) {
      throw FormatException(
          'protobuf: truncated $count-byte field at offset $_pos');
    }
    _pos += count;
  }
}
