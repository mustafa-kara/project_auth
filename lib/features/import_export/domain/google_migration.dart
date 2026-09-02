/// Google Authenticator migration batches and the collector that stitches a
/// multi-QR export back together (plan §3).
///
/// W2 drives [GoogleMigrationCollector] from the scan screen through
/// `MigrationScanController`, so the shapes here are frozen for both workers.
///
/// Pure Dart: no Flutter, no plugins — the whole merge rule set is unit
/// testable on the host VM without a camera.
///
/// SECURITY: [MigrationBatch.accounts] carries live secrets. It stays in memory
/// only while the scan screen is open; the screen calls [
/// GoogleMigrationCollector.reset] on dispose and never logs or copies a batch.
library;

import '../../../core/otp/otp_account.dart';
import 'import_models.dart';

/// One decoded `otpauth-migration://` QR: the batch coordinates Google stamped
/// on it plus everything the parser could and could not map.
///
/// [batchId] identifies the export as a whole and MAY be 0 or negative — Google
/// writes a signed `int32`. [batchIndex] is 0-based within [batchSize].
/// [version] is validated but never a reason to reject (plan §0).
class MigrationBatch {
  final int version;
  final int batchSize;
  final int batchIndex;
  final int batchId;
  final List<OtpAccount> accounts;
  final List<SkippedEntry> skipped;

  const MigrationBatch({
    required this.version,
    required this.batchSize,
    required this.batchIndex,
    required this.batchId,
    required this.accounts,
    this.skipped = const <SkippedEntry>[],
  });
}

/// What [GoogleMigrationCollector.add] did with a batch. Every non-[added]
/// outcome leaves the collector untouched, so a stray or hostile QR can never
/// corrupt what the user already scanned.
enum MigrationAddOutcome {
  /// Stored. The batch was new and consistent with the ones before it.
  added,

  /// This [MigrationBatch.batchIndex] was already scanned — ignored.
  duplicateIndex,

  /// Different [MigrationBatch.batchId] or [MigrationBatch.batchSize] than the
  /// batches already collected: a QR from another export. Never merged; the UI
  /// offers to start over.
  differentBatch,

  /// Self-inconsistent coordinates (`batchSize` outside 1..[
  /// GoogleMigrationCollector.maxBatchSize], or `batchIndex` outside
  /// 0..`batchSize - 1`).
  invalidBatch,

  /// Accepting it would push the collected account count past
  /// [GoogleMigrationCollector.maxAccounts].
  full,
}

/// Accumulates the QR codes of one multi-part Google Authenticator export.
///
/// The first accepted batch pins [batchId] and [batchSize]; every later batch
/// must agree on both. Order does not matter — [toParsedImport] emits accounts
/// ordered by `batchIndex` regardless of scan order — and a partial scan is a
/// legitimate result (the user may stop early; dedupe protects a later
/// completion run).
class GoogleMigrationCollector {
  /// Largest `batch_size` accepted. Google's exporter splits far below this;
  /// a larger claim is malformed input.
  static const int maxBatchSize = 16;

  /// Ceiling on accounts collected across all batches of one export.
  static const int maxAccounts = 1024;

  /// Accepted batches keyed by `batchIndex`. A map rather than a fixed-length
  /// list because `batchSize` is only known after the first accepted QR and the
  /// user may scan the codes in any order.
  final Map<int, MigrationBatch> _batches = <int, MigrationBatch>{};

  /// Null until the first batch is accepted. Nullable rather than
  /// sentinel-valued because 0 is a legitimate `batch_id`; emptiness is decided
  /// by [_batches], never by comparing this against a magic number.
  int? _batchId;

  int _batchSize = 0;

  /// The pinned export id, or null while nothing has been collected. Nullable
  /// rather than sentinel-valued because 0 is a legitimate `batch_id`.
  int? get batchId => _batchId;

  /// The pinned `batch_size`, or 0 while nothing has been collected.
  int get batchSize => _batchSize;

  /// How many distinct batch indices have been collected.
  int get scannedCount => _batches.length;

  /// Whether every index of the export has been scanned.
  bool get isComplete => _batchSize > 0 && _batches.length >= _batchSize;

  /// Whether nothing has been collected yet.
  bool get isEmpty => _batches.isEmpty;

  /// Merges [batch]; see [MigrationAddOutcome] for every way this can decline.
  ///
  /// Every check runs before a single field is written, so a declined batch
  /// leaves the collector byte-for-byte as it was.
  MigrationAddOutcome add(MigrationBatch batch) {
    // 1. Self-consistency, judged without any reference to prior state: a QR
    //    claiming index 3 of 2 is malformed no matter what came before.
    if (batch.batchSize < 1 || batch.batchSize > maxBatchSize) {
      return MigrationAddOutcome.invalidBatch;
    }
    if (batch.batchIndex < 0 || batch.batchIndex >= batch.batchSize) {
      return MigrationAddOutcome.invalidBatch;
    }

    // 2. Agreement with the pinned export. Checked before the duplicate test so
    //    a foreign QR that happens to reuse an index reads as "other export"
    //    (which offers "start over") rather than "already scanned".
    if (_batches.isNotEmpty &&
        (batch.batchId != _batchId || batch.batchSize != _batchSize)) {
      return MigrationAddOutcome.differentBatch;
    }

    if (_batches.containsKey(batch.batchIndex)) {
      return MigrationAddOutcome.duplicateIndex;
    }

    var collected = 0;
    for (final stored in _batches.values) {
      collected += stored.accounts.length;
    }
    if (collected + batch.accounts.length > maxAccounts) {
      return MigrationAddOutcome.full;
    }

    _batchId = batch.batchId;
    _batchSize = batch.batchSize;
    _batches[batch.batchIndex] = batch;
    return MigrationAddOutcome.added;
  }

  /// Flattens what has been collected into a [ParsedImport] with
  /// [ImportSource.googleAuth]: accounts and skipped entries concatenated in
  /// ascending `batchIndex` order, so the preview is stable across scan orders.
  ParsedImport toParsedImport() {
    final indices = _batches.keys.toList()..sort();
    final accounts = <OtpAccount>[];
    final skipped = <SkippedEntry>[];
    for (final index in indices) {
      final batch = _batches[index]!;
      accounts.addAll(batch.accounts);
      skipped.addAll(batch.skipped);
    }
    return ParsedImport(
      source: ImportSource.googleAuth,
      accounts: accounts,
      skipped: skipped,
    );
  }

  /// Drops all collected state, including the pinned [batchId]/[batchSize].
  /// Called when the user starts over and from the scan screen's `dispose`.
  void reset() {
    _batches.clear();
    _batchId = null;
    _batchSize = 0;
  }
}
