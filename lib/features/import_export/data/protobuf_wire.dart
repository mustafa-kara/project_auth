/// Minimal hand-written protobuf wire reader — just enough for Google
/// Authenticator's `MigrationPayload` (plan §1).
///
/// Filled by W1. No codegen and no `protobuf` package on purpose: the project
/// carries no generated code anywhere, and proto3 field *presence* for the HOTP
/// `counter` (absent vs. explicit 0) is only observable with a reader that
/// reports which tags actually appeared — a generated message would hand us a
/// default 0 and we would silently desynchronize the token.
///
/// Pure Dart: no Flutter, no IO, no plugins, so it runs on the host VM and
/// inside `Isolate.run`.
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
  /// Reads [bytes] from offset 0 up to [end] (defaults to `bytes.length`).
  /// [end] lets a caller scope a reader to a nested message without copying.
  ProtobufReader(Uint8List bytes, {int? end}) {
    throw UnimplementedError('W1 fills this');
  }

  /// Whether any unread byte remains before the end of this reader's range.
  bool get hasMore => throw UnimplementedError('W1 fills this');

  /// Reads a tag byte group. Field number 0 is illegal in protobuf →
  /// `FormatException`.
  ({int field, int wireType}) readTag() =>
      throw UnimplementedError('W1 fills this');

  /// Reads a base-128 varint as a 64-bit signed value. More than
  /// [ProtobufLimits.maxVarintBytes] bytes, or a truncated buffer →
  /// `FormatException`.
  int readVarint() => throw UnimplementedError('W1 fills this');

  /// Reads a length-delimited field and returns a **view** onto the backing
  /// buffer (`Uint8List.sublistView`, no copy). A negative length or one that
  /// runs past the end of the range → `FormatException`.
  Uint8List readLengthDelimited() => throw UnimplementedError('W1 fills this');

  /// Skips an unknown field of [wireType]. Supports 0 (varint), 1 (64-bit),
  /// 2 (length-delimited) and 5 (32-bit); the deprecated group types 3 and 4
  /// are rejected with `FormatException` instead of being skipped, because
  /// their end is only findable by recursive scanning.
  void skipField(int wireType) => throw UnimplementedError('W1 fills this');
}
