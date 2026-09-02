/// Google Authenticator export QR (`otpauth-migration://offline?data=…`) →
/// [MigrationBatch] (plan §2).
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
///   "promoting" one would produce codes that do not work. There is no issuer
///   heuristic on any import path — `aegis_parser.dart` and `twofas_parser.dart`
///   likewise treat the declared type (`type` / `otp.tokenType`) as the only
///   authority — and the migration schema has no type field at all, so a Google
///   entry named "Steam" is an ordinary 6-digit TOTP and must stay one.
/// - A HOTP entry whose `counter` field is *absent* is skipped
///   (`SkipReason.invalidFields`) rather than defaulted to 0 — a guessed counter
///   desynchronizes the token permanently. An entry that explicitly carries
///   `counter = 0` is honoured, which is exactly the distinction a generated
///   proto3 message could not make.
/// - `period` is not in the schema at all: Google only issues 30-second TOTP,
///   so every mapped account gets [_defaultPeriod].
/// - `version` is read and reported but never a reason to reject: a future
///   exporter bumping it while keeping the field numbers stable should still
///   import.
///
/// SECURITY: the payload is a bundle of plaintext secrets. No secret, no raw
/// URI and no base64 fragment may appear in a `SkippedEntry`, an exception
/// message or a log line. `OtpAccount` failures are caught and replaced with
/// fixed strings, exactly as in `aegis_parser.dart`.
library;

import 'dart:convert';

// `Uint8List` and `visibleForTesting` only — no widgets, no bindings, so this
// parser still runs inside `Isolate.run` and on the host VM.
import 'package:flutter/foundation.dart';

import '../../../core/otp/base32.dart';
import '../../../core/otp/otp_account.dart';
import '../../../core/otp/otp_algorithm.dart';
import '../domain/google_migration.dart';
import '../domain/import_exceptions.dart';
import '../domain/import_models.dart';
import 'protobuf_wire.dart';

/// Account name used when the entry carries neither a name nor an issuer
/// (plan D4). User-facing text is Turkish by project convention.
const String _unnamedAccount = '(isimsiz)';

/// The only period Google Authenticator issues; the schema has no field for it.
const int _defaultPeriod = 30;

/// `MigrationPayload` field numbers (plan §0).
const int _fPayloadOtpParameters = 1;
const int _fPayloadVersion = 2;
const int _fPayloadBatchSize = 3;
const int _fPayloadBatchIndex = 4;
const int _fPayloadBatchId = 5;

/// `OtpParameters` field numbers (plan §0).
const int _fEntrySecret = 1;
const int _fEntryName = 2;
const int _fEntryIssuer = 3;
const int _fEntryAlgorithm = 4;
const int _fEntryDigits = 5;
const int _fEntryType = 6;
const int _fEntryCounter = 7;

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
  static MigrationBatch parseUri(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const MalformedMigrationUriException('empty QR string');
    }
    if (trimmed.length > maxUriLength) {
      throw const MalformedMigrationUriException(
        'QR string over the size limit',
      );
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null) {
      throw const MalformedMigrationUriException('not a parseable URI');
    }
    if (uri.scheme.toLowerCase() != scheme) {
      throw const MalformedMigrationUriException('scheme is not $scheme');
    }
    if (uri.host.toLowerCase() != host) {
      throw const MalformedMigrationUriException('host is not $host');
    }

    // `uri.query` is the still-percent-encoded query. Splitting it by hand and
    // decoding each value with `Uri.decodeComponent` is the whole point: the
    // form-urlencoded rules behind `Uri.queryParameters` would rewrite every
    // base64 `+` as a space.
    final rawData = _queryValue(uri.query, 'data');
    if (rawData == null || rawData.isEmpty) {
      throw const MalformedMigrationUriException('no "data" parameter');
    }

    final String decoded;
    try {
      decoded = Uri.decodeComponent(rawData);
    } on ArgumentError {
      throw const MalformedMigrationUriException(
        '"data" is not valid percent-encoding',
      );
    } on FormatException {
      throw const MalformedMigrationUriException(
        '"data" is not valid percent-encoding',
      );
    }

    return parsePayload(_decodeBase64(decoded));
  }

  /// The protobuf half of [parseUri], on already base64-decoded bytes.
  /// Exposed so the golden vectors can be exercised without going through URI
  /// encoding; production always enters via [parseUri].
  @visibleForTesting
  static MigrationBatch parsePayload(Uint8List payload) {
    if (payload.length > maxPayloadBytes) {
      throw const MalformedMigrationUriException('payload over the size limit');
    }

    final reader = ProtobufReader(payload);
    final accounts = <OtpAccount>[];
    final skipped = <SkippedEntry>[];
    var version = 0;
    var batchSize = 0;
    var batchIndex = 0;
    var batchId = 0;
    var entries = 0;

    while (reader.hasMore) {
      final tag = reader.readTag();
      switch (tag.field) {
        case _fPayloadOtpParameters:
          if (tag.wireType != 2) {
            reader.skipField(tag.wireType);
            break;
          }
          // Read the sub-message range first so the cursor advances even when
          // the entry itself turns out to be unmappable.
          final bytes = reader.readLengthDelimited();
          entries++;
          if (entries > maxEntriesPerBatch) {
            throw FormatException(
              'migration payload holds more than $maxEntriesPerBatch entries',
            );
          }
          _collectEntry(bytes, accounts, skipped);
        case _fPayloadVersion:
          // Repeated scalars: last one wins, matching proto3 merge semantics.
          version = _scalar(reader, tag.wireType, version);
        case _fPayloadBatchSize:
          batchSize = _scalar(reader, tag.wireType, batchSize);
        case _fPayloadBatchIndex:
          batchIndex = _scalar(reader, tag.wireType, batchIndex);
        case _fPayloadBatchId:
          batchId = _scalar(reader, tag.wireType, batchId);
        default:
          // Unknown field: skipped, never fatal — a newer exporter may add
          // fields we do not model, and the entries we do understand still
          // import.
          reader.skipField(tag.wireType);
      }
    }

    return MigrationBatch(
      version: version,
      batchSize: batchSize,
      batchIndex: batchIndex,
      batchId: batchId,
      accounts: accounts,
      skipped: skipped,
    );
  }

  /// Reads a varint scalar, or skips the field and keeps [current] when the
  /// wire type is not the one the schema declares (a field renumbered by a
  /// future exporter must not corrupt a batch coordinate).
  static int _scalar(ProtobufReader reader, int wireType, int current) {
    if (wireType != 0) {
      reader.skipField(wireType);
      return current;
    }
    return reader.readVarint();
  }

  /// Value of [key] in an already-encoded query string, or null.
  ///
  /// Only the value is percent-decoded, by the caller: decoding before the
  /// `&`/`=` split would let an encoded separator forge an extra parameter.
  ///
  /// A repeated key (`?data=a&data=b`) resolves to the **first** occurrence and
  /// the rest are ignored — the same rule `Uri.queryParameters` applies. There
  /// is no legitimate export with two `data` parameters, so the choice only
  /// decides which half of a malformed QR is rejected; pinning it keeps the
  /// answer from drifting into "last wins" on a later refactor.
  static String? _queryValue(String query, String key) {
    if (query.isEmpty) return null;
    for (final pair in query.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      final name = eq < 0 ? pair : pair.substring(0, eq);
      if (name.toLowerCase() != key) continue;
      return eq < 0 ? '' : pair.substring(eq + 1);
    }
    return null;
  }

  /// base64 (standard or URL-safe, padded or not) → bytes.
  ///
  /// The size ceiling is applied to the *encoded* length first, so an oversized
  /// blob never becomes a byte array.
  static Uint8List _decodeBase64(String encoded) {
    final normalized = encoded.trim().replaceAll('-', '+').replaceAll('_', '/');
    final stripped = normalized.replaceAll('=', '');
    if (stripped.isEmpty) {
      throw const MalformedMigrationUriException('"data" is empty');
    }
    // 4 base64 characters carry 3 bytes; a length of 1 mod 4 encodes nothing.
    final remainder = stripped.length % 4;
    if (remainder == 1) {
      throw const MalformedMigrationUriException('"data" is not valid base64');
    }
    if ((stripped.length ~/ 4) * 3 > maxPayloadBytes) {
      throw const MalformedMigrationUriException('payload over the size limit');
    }
    final padded = remainder == 0 ? stripped : stripped + '=' * (4 - remainder);

    final Uint8List bytes;
    try {
      bytes = base64.decode(padded);
    } on FormatException {
      // The message from `base64.decode` quotes the offending characters —
      // i.e. a slice of the secret bundle. It is replaced, never propagated.
      throw const MalformedMigrationUriException('"data" is not valid base64');
    }
    if (bytes.isEmpty) {
      throw const MalformedMigrationUriException(
        '"data" decoded to zero bytes',
      );
    }
    return bytes;
  }

  /// Decodes one `OtpParameters` sub-message and appends either an account or a
  /// [SkippedEntry]. Structural damage propagates as `FormatException` (the
  /// whole QR is unreadable); a merely unmappable entry is recorded and the
  /// rest of the batch still imports.
  static void _collectEntry(
    Uint8List bytes,
    List<OtpAccount> accounts,
    List<SkippedEntry> skipped,
  ) {
    final _RawEntry raw;
    try {
      raw = _decodeEntry(bytes);
    } on _Skip catch (skip) {
      // Thrown before any name is readable (malformed UTF-8), so there is no
      // label to show — deliberately null rather than a byte dump.
      skipped.add(SkippedEntry(reason: skip.reason, detail: skip.detail));
      return;
    }

    final naming = _naming(raw);
    try {
      accounts.add(_map(raw, naming));
    } on _Skip catch (skip) {
      skipped.add(
        SkippedEntry(
          label: naming.label,
          reason: skip.reason,
          detail: skip.detail,
        ),
      );
    }
  }

  static _RawEntry _decodeEntry(Uint8List bytes) {
    final reader = ProtobufReader(bytes);
    Uint8List? secret;
    var name = '';
    var issuer = '';
    var algorithm = 0;
    var digits = 0;
    var type = 0;
    var counter = 0;
    // Proto3 presence, the reason this decoder exists at all: a HOTP entry
    // whose counter tag never appeared is unimportable, one that carries an
    // explicit 0 is fine.
    var hasCounter = false;

    while (reader.hasMore) {
      final tag = reader.readTag();
      switch (tag.field) {
        case _fEntrySecret:
          if (tag.wireType != 2) {
            reader.skipField(tag.wireType);
            break;
          }
          final value = reader.readLengthDelimited();
          if (value.length > ProtobufLimits.maxSecretBytes) {
            throw FormatException(
              'OtpParameters: secret over ${ProtobufLimits.maxSecretBytes} bytes',
            );
          }
          secret = value;
        case _fEntryName:
          name = _string(reader, tag.wireType, name);
        case _fEntryIssuer:
          issuer = _string(reader, tag.wireType, issuer);
        case _fEntryAlgorithm:
          algorithm = _scalar(reader, tag.wireType, algorithm);
        case _fEntryDigits:
          digits = _scalar(reader, tag.wireType, digits);
        case _fEntryType:
          type = _scalar(reader, tag.wireType, type);
        case _fEntryCounter:
          if (tag.wireType != 0) {
            reader.skipField(tag.wireType);
            break;
          }
          counter = reader.readVarint();
          hasCounter = true;
        default:
          reader.skipField(tag.wireType);
      }
    }

    return _RawEntry(
      secret: secret,
      name: name,
      issuer: issuer,
      algorithm: algorithm,
      digits: digits,
      type: type,
      counter: counter,
      hasCounter: hasCounter,
    );
  }

  /// Reads a UTF-8 string field. Malformed UTF-8 drops the single entry
  /// (`allowMalformed: false`) rather than the whole payload — the other
  /// entries in the QR are still importable.
  static String _string(ProtobufReader reader, int wireType, String current) {
    if (wireType != 2) {
      reader.skipField(wireType);
      return current;
    }
    final bytes = reader.readLengthDelimited();
    if (bytes.length > ProtobufLimits.maxStringBytes) {
      throw FormatException(
        'OtpParameters: string over ${ProtobufLimits.maxStringBytes} bytes',
      );
    }
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const _Skip(
        SkipReason.invalidFields,
        'entry has a non-UTF-8 text field',
      );
    }
  }

  /// Splits `name` into issuer/account exactly as `otpauth_uri.dart` does
  /// (first `:` wins), then applies the issuer precedence: the dedicated
  /// `issuer` field beats the one embedded in the label, and an entry with
  /// neither still gets a non-blank row in the vault.
  static _Naming _naming(_RawEntry raw) {
    String? labelIssuer;
    String accountName;
    final colon = raw.name.indexOf(':');
    if (colon >= 0) {
      labelIssuer = raw.name.substring(0, colon).trim();
      accountName = raw.name.substring(colon + 1).trim();
    } else {
      accountName = raw.name.trim();
    }

    final field = raw.issuer.trim();
    final embedded = (labelIssuer ?? '').trim();
    final String? issuer = field.isNotEmpty
        ? field
        : (embedded.isNotEmpty ? embedded : null);
    if (accountName.isEmpty) {
      accountName = issuer ?? _unnamedAccount;
    }
    return _Naming(issuer: issuer, accountName: accountName);
  }

  static OtpAccount _map(_RawEntry raw, _Naming naming) {
    final secretBytes = raw.secret;
    if (secretBytes == null || secretBytes.isEmpty) {
      throw const _Skip(SkipReason.invalidSecret, 'secret missing or empty');
    }
    // Base32 ENCODE, not decode: the payload carries raw bytes, and every byte
    // string has a Base32 form — so there is no "invalid Base32" path here and
    // nothing that could quote a secret in an error message.
    final secret = Base32.encode(secretBytes);

    final algorithm = switch (raw.algorithm) {
      // UNSPECIFIED means "the default", which for OTP is SHA1.
      0 || 1 => OtpAlgorithm.sha1,
      2 => OtpAlgorithm.sha256,
      3 => OtpAlgorithm.sha512,
      // MD5 is in Google's enum but this app's OTP engine does not implement
      // it; mapping it to SHA1 would generate wrong codes silently.
      4 => throw const _Skip(SkipReason.unsupportedType, 'algorithm=MD5'),
      _ => throw _Skip(SkipReason.invalidFields, 'algorithm=${raw.algorithm}'),
    };

    final digits = switch (raw.digits) {
      0 || 1 => 6,
      2 => 8,
      _ => throw _Skip(SkipReason.invalidFields, 'digits=${raw.digits}'),
    };

    final type = switch (raw.type) {
      // An entry that never says what it is cannot be guessed: HOTP and TOTP
      // are not interchangeable.
      0 => throw const _Skip(SkipReason.unsupportedType, 'type=unspecified'),
      1 => OtpType.hotp,
      2 => OtpType.totp,
      _ => throw _Skip(SkipReason.unsupportedType, 'type=${raw.type}'),
    };

    final int counter;
    if (type == OtpType.hotp) {
      if (!raw.hasCounter) {
        throw const _Skip(
          SkipReason.invalidFields,
          'HOTP entry has no counter',
        );
      }
      if (raw.counter < 0) {
        throw const _Skip(SkipReason.invalidFields, 'counter is negative');
      }
      counter = raw.counter;
    } else {
      counter = 0;
    }

    try {
      return OtpAccount(
        secret: secret,
        type: type,
        issuer: naming.issuer,
        accountName: naming.accountName,
        algorithm: algorithm,
        digits: digits,
        period: _defaultPeriod,
        counter: counter,
      );
    } on FormatException {
      // Last-resort net for values the checks above did not screen. The message
      // is NOT propagated: `OtpAccount.validate` quotes the secret on the
      // Base32 path.
      throw _Skip(
        SkipReason.invalidFields,
        'digits=$digits period=$_defaultPeriod counter=$counter',
      );
    } on ArgumentError {
      throw _Skip(
        SkipReason.invalidFields,
        'digits=$digits period=$_defaultPeriod counter=$counter',
      );
    }
  }
}

/// One `OtpParameters` message, still in wire terms: enum values are integers
/// and `secret` is raw bytes. Mapping to the app's domain happens afterwards so
/// that a decode failure and a mapping failure stay distinguishable.
class _RawEntry {
  final Uint8List? secret;
  final String name;
  final String issuer;
  final int algorithm;
  final int digits;
  final int type;
  final int counter;
  final bool hasCounter;

  const _RawEntry({
    required this.secret,
    required this.name,
    required this.issuer,
    required this.algorithm,
    required this.digits,
    required this.type,
    required this.counter,
    required this.hasCounter,
  });
}

/// Display identity of an entry, resolved before mapping so a rejected entry is
/// still recognizable in the preview.
class _Naming {
  final String? issuer;
  final String accountName;

  const _Naming({required this.issuer, required this.accountName});

  /// "Issuer (account)", or just the account when there is no issuer — the same
  /// shape `OtpAccount.label` and `aegis_parser.dart` produce.
  String? get label {
    if (issuer != null && issuer!.isNotEmpty) return '$issuer ($accountName)';
    return accountName.isEmpty ? null : accountName;
  }
}

/// Internal control-flow signal: "drop this entry, keep the QR".
class _Skip implements Exception {
  final SkipReason reason;
  final String detail;
  const _Skip(this.reason, this.detail);
}
