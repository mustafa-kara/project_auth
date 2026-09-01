/// Google Authenticator migration batches and the collector that stitches a
/// multi-QR export back together (plan §3).
///
/// Filled by W1 ([GoogleMigrationCollector] logic); W2 drives it from the scan
/// screen through `MigrationScanController`, so the shapes here are frozen for
/// both workers.
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

  /// The pinned export id, or null while nothing has been collected. Nullable
  /// rather than sentinel-valued because 0 is a legitimate `batch_id`.
  int? get batchId => throw UnimplementedError('W1 fills this');

  /// The pinned `batch_size`, or 0 while nothing has been collected.
  int get batchSize => throw UnimplementedError('W1 fills this');

  /// How many distinct batch indices have been collected.
  int get scannedCount => throw UnimplementedError('W1 fills this');

  /// Whether every index of the export has been scanned.
  bool get isComplete => throw UnimplementedError('W1 fills this');

  /// Whether nothing has been collected yet.
  bool get isEmpty => throw UnimplementedError('W1 fills this');

  /// Merges [batch]; see [MigrationAddOutcome] for every way this can decline.
  MigrationAddOutcome add(MigrationBatch batch) =>
      throw UnimplementedError('W1 fills this');

  /// Flattens what has been collected into a [ParsedImport] with
  /// [ImportSource.googleAuth]: accounts and skipped entries concatenated in
  /// ascending `batchIndex` order, so the preview is stable across scan orders.
  ParsedImport toParsedImport() => throw UnimplementedError('W1 fills this');

  /// Drops all collected state, including the pinned [batchId]/[batchSize].
  /// Called when the user starts over and from the scan screen's `dispose`.
  void reset() => throw UnimplementedError('W1 fills this');
}
