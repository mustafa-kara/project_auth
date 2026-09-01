/// Orchestrates raw file text → preview the user can confirm before anything is
/// written to the vault.
///
/// Filled by W2 (parsing runs off the UI isolate; tests drive the sync path).
/// This layer never touches the vault itself — the caller applies the result via
/// `VaultCubit.addAll`, so a preview is always side-effect free.
library;

import '../../../core/otp/otp_account.dart';
import 'backup_service.dart';
import 'import_models.dart';

/// What the confirm screen renders: the accounts that would be added plus the
/// audit trail of everything that would not.
class ImportPreview {
  final ImportSource source;
  final List<OtpAccount> toAdd;
  final List<SkippedEntry> skipped;

  const ImportPreview({
    required this.source,
    required this.toAdd,
    this.skipped = const <SkippedEntry>[],
  });

  int get addCount => toAdd.length;

  /// Entries dropped because we already have them (in this file or in the vault)
  /// — reported separately from real failures, since they are not a problem.
  int get duplicateCount => skipped
      .where((e) =>
          e.reason == SkipReason.duplicateInFile ||
          e.reason == SkipReason.alreadyInVault)
      .length;

  /// Entries dropped because we could not import them (unsupported/invalid).
  int get skippedCount => skipped.length - duplicateCount;
}

class ImportService {
  /// Source parsers, tried after [detect] picks a format. Defaults to the empty
  /// set until W1's parsers are wired in.
  final List<ImportParser> parsers;

  final BackupService backup;

  ImportService({List<ImportParser>? parsers, required this.backup})
      : parsers = parsers ?? const <ImportParser>[];

  /// Hard ceiling on file size (8 MiB): a real export is orders of magnitude
  /// smaller, and the whole file is decoded in memory.
  static const int maxBytes = 8 * 1024 * 1024;

  /// Decodes [raw] far enough to fingerprint it. Throws
  /// `MalformedImportFileException` when it is not a JSON object.
  ImportSource detect(String raw) {
    throw UnimplementedError('W2 fills this');
  }

  /// Parses, deduplicates against [existing] and returns the preview.
  /// [backupPassword] is required only for our own encrypted backup format.
  Future<ImportPreview> preview({
    required String raw,
    required List<OtpAccount> existing,
    String? backupPassword,
  }) {
    throw UnimplementedError('W2 fills this');
  }
}
