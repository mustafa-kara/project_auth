/// Import domain contract: recognized file kinds, per-entry skip bookkeeping and
/// the parser port every source implementation plugs into.
///
/// Filled by W1 (`data/aegis_parser.dart`, `data/twofas_parser.dart`); W2 and W3
/// only consume these types, so the shapes here are frozen for all three workers.
library;

import 'package:equatable/equatable.dart';

import '../../../core/otp/otp_account.dart';

/// Sources this app can read. [unknown] means the root JSON matched no known
/// fingerprint, which is a user-facing error rather than a silent no-op.
///
/// [googleAuth] is the odd one out: it never comes from a file. Google
/// Authenticator only exports `otpauth-migration://` QR codes, so that source is
/// produced by `GoogleAuthParser`/`GoogleMigrationCollector` from scanned URIs
/// and `detectSource` (JSON fingerprinting) deliberately never returns it.
enum ImportSource { aegis, twofas, googleAuth, projectauthBackup, unknown }

/// Why a single entry was dropped. A single bad entry must never fail the whole
/// import, so every drop is recorded instead of thrown.
enum SkipReason {
  /// Entry type is not TOTP/HOTP/Steam (Yandex, mOTP, ...).
  unsupportedType,

  /// Secret missing, empty or not decodable Base32.
  invalidSecret,

  /// digits/period/counter/algorithm outside the [OtpAccount] contract.
  invalidFields,

  /// The same dedupe key already appeared earlier in this file (first wins).
  duplicateInFile,

  /// The same dedupe key already exists in the vault.
  alreadyInVault,
}

/// One dropped entry, shown in the import preview.
///
/// SECURITY: the secret is NEVER stored here. This object reaches widget trees,
/// error reports and (in debug) diagnostics, so [label]/[detail] must stay
/// non-sensitive display strings.
class SkippedEntry extends Equatable {
  /// Display label, conventionally "issuer (accountName)". null when the source
  /// entry carried no usable name.
  final String? label;

  final SkipReason reason;

  /// Short, non-sensitive extra context (e.g. the unsupported type name).
  final String? detail;

  const SkippedEntry({required this.reason, this.label, this.detail});

  @override
  List<Object?> get props => [label, reason, detail];
}

/// Result of parsing one source file: everything that survived plus the audit
/// trail of what did not.
class ParsedImport {
  final ImportSource source;
  final List<OtpAccount> accounts;
  final List<SkippedEntry> skipped;

  const ParsedImport({
    required this.source,
    required this.accounts,
    this.skipped = const <SkippedEntry>[],
  });
}

/// Port for a single source format. Implementations are pure Dart (no IO, no
/// plugins) so they can run inside `Isolate.run` and be tested on the host VM.
abstract interface class ImportParser {
  /// The format this parser claims; must match the detector's verdict.
  ImportSource get source;

  /// Parses an already decoded root JSON object. Throws only for
  /// file-level failures (see `import_exceptions.dart`); per-entry problems
  /// become [SkippedEntry] records.
  ParsedImport parse(Map<String, dynamic> json);
}
