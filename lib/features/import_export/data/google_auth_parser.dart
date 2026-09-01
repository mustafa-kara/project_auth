/// Google Authenticator export QR (`otpauth-migration://offline?data=…`) →
/// [MigrationBatch] (plan §2).
///
/// Filled by W1, except [looksLikeMigrationUri] which is final here: the scan
/// screen (W2) needs the sniff before either worker's body exists, and the test
/// seam depends on it.
///
/// Stateless by design — every member is static, so nothing is registered in
/// the locator and `scan_page.dart` can call it without DI.
///
/// Notable decisions (plan §2):
/// - `Uri.queryParameters` is NOT used: it applies `application/x-www-form-
///   urlencoded` rules and turns a base64 `+` into a space, silently corrupting
///   every payload that happens to contain one. The query is split by hand on
///   `&`/`=` and decoded with `Uri.decodeComponent`.
/// - Scheme and host are compared case-insensitively; everything else about the
///   URI (userinfo, path, fragment, extra query keys) is ignored.
/// - Steam is never inferred: Google Authenticator cannot hold a Steam token, so
///   "promoting" one would produce codes that do not work.
/// - A HOTP entry whose `counter` field is *absent* is skipped
///   (`SkipReason.invalidFields`) rather than defaulted to 0 — a guessed counter
///   desynchronizes the token permanently.
///
/// SECURITY: the payload is a bundle of plaintext secrets. No secret, no raw
/// URI and no base64 fragment may appear in a `SkippedEntry`, an exception
/// message or a log line. `Base32.decode`/`OtpAccount` failures are caught and
/// replaced with fixed strings, exactly as in `aegis_parser.dart`.
library;

import 'package:flutter/foundation.dart';

import '../domain/google_migration.dart';
import 'protobuf_wire.dart';

abstract final class GoogleAuthParser {
  /// The only scheme Google Authenticator exports (compared lower-cased).
  static const String scheme = 'otpauth-migration';

  /// The only host it emits (compared lower-cased).
  static const String host = 'offline';

  /// Longest raw QR string accepted, before any decoding (8 KiB).
  static const int maxUriLength = 8 * 1024;

  /// Largest decoded payload; estimated from the base64 length first so an
  /// oversized blob is refused before it is materialized.
  static const int maxPayloadBytes = ProtobufLimits.maxPayloadBytes;

  /// Most `OtpParameters` entries accepted in one QR.
  static const int maxEntriesPerBatch = ProtobufLimits.maxEntriesPerBatch;

  /// Cheap sniff used by the scan screen to route a barcode into migration mode
  /// instead of the single-token `otpauth://` path. Intentionally lenient — it
  /// only decides *which* parser gets the string; [parseUri] does the real
  /// validation and owns every rejection.
  static bool looksLikeMigrationUri(String raw) =>
      raw.trimLeft().toLowerCase().startsWith('$scheme://');

  /// Parses a scanned QR string.
  ///
  /// Throws `MalformedMigrationUriException` for anything wrong at the URI or
  /// base64 layer (wrong scheme/host, missing or empty `data`, undecodable
  /// base64, over [maxUriLength]/[maxPayloadBytes]) and `FormatException` for a
  /// structurally broken protobuf body. Individual unmappable entries are NOT
  /// thrown — they come back as [MigrationBatch.skipped].
  static MigrationBatch parseUri(String raw) =>
      throw UnimplementedError('W1 fills this');

  /// The protobuf half of [parseUri], on already base64-decoded bytes.
  /// Exposed so the golden vectors can be exercised without going through URI
  /// encoding; production always enters via [parseUri].
  @visibleForTesting
  static MigrationBatch parsePayload(Uint8List payload) =>
      throw UnimplementedError('W1 fills this');
}
