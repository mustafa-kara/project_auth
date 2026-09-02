/// Camera-free brain of the Google Authenticator migration scan (plan §5, R3).
///
/// Filled by W2. `ScanPage` keeps one of these and does nothing with a scanned
/// string except hand it to [MigrationScanController.handleRaw] and render the
/// returned [MigrationScanEvent].
///
/// WHY A SEPARATE CLASS: `MobileScanner` needs a real camera, which the host VM
/// running `flutter test` does not have — a widget test can neither render the
/// preview nor synthesize a `BarcodeCapture`. Every migration rule (batch
/// stitching, duplicate and cross-export detection, the malformed-QR path, when
/// the preview may be built) therefore lives here, in plain Dart with no
/// Flutter, no plugin and no `BuildContext`, and is covered without a camera.
/// What stays in the page is only what a widget test can actually drive:
/// layout, dialogs, snackbars and navigation.
///
/// SECURITY: raw QR strings are consumed and dropped — never stored, logged or
/// copied to the clipboard. Collected accounts live inside the collector until
/// [MigrationScanController.reset], which the page calls on dispose.
library;

import 'package:equatable/equatable.dart';

import '../../../core/otp/otp_account.dart';
import '../../import_export/data/google_auth_parser.dart';
import '../../import_export/domain/google_migration.dart';
import '../../import_export/domain/import_service.dart';

/// Outcome of feeding one scanned string to [MigrationScanController.handleRaw]
/// — the single value the page turns into UI (counter text, snackbar, dialog).
sealed class MigrationScanEvent extends Equatable {
  const MigrationScanEvent();

  @override
  List<Object?> get props => const <Object?>[];
}

/// A new batch was stored and the export is still incomplete.
/// [scanned] of [total] codes are in.
final class MigrationBatchAdded extends MigrationScanEvent {
  final int scanned;
  final int total;
  const MigrationBatchAdded(this.scanned, this.total);

  @override
  List<Object?> get props => [scanned, total];
}

/// A new batch was stored and it was the last one missing: every code of the
/// export has now been scanned.
final class MigrationScanComplete extends MigrationScanEvent {
  final int scanned;
  final int total;
  const MigrationScanComplete(this.scanned, this.total);

  @override
  List<Object?> get props => [scanned, total];
}

/// This code had already been scanned — state unchanged.
final class MigrationDuplicateScan extends MigrationScanEvent {
  const MigrationDuplicateScan();
}

/// The code belongs to a different export than the ones already collected.
/// Nothing was merged; the page asks whether to start over.
final class MigrationDifferentBatch extends MigrationScanEvent {
  const MigrationDifferentBatch();
}

/// The code decoded but its batch coordinates are self-inconsistent.
final class MigrationInvalidBatch extends MigrationScanEvent {
  const MigrationInvalidBatch();
}

/// Accepting the code would exceed [GoogleMigrationCollector.maxAccounts].
final class MigrationScanFull extends MigrationScanEvent {
  const MigrationScanFull();
}

/// Not a readable `otpauth-migration://` export QR (bad URI, base64 or
/// protobuf). Deliberately one event for all three: the user-facing message is
/// the same and the cause must not be disclosed.
final class MigrationMalformedQr extends MigrationScanEvent {
  const MigrationMalformedQr();
}

/// Stateful for the lifetime of one scan session; owns the collector.
class MigrationScanController {
  /// [collector] is injectable so tests can pre-seed or observe it; production
  /// passes nothing and gets a fresh one.
  ///
  /// [parse] is injectable for the same reason: `GoogleAuthParser.parseUri` is
  /// static, so a widget/unit test could not otherwise exercise the malformed
  /// and multi-batch paths without hand-building real protobuf payloads.
  /// Production passes neither.
  MigrationScanController(
    ImportService service, {
    GoogleMigrationCollector? collector,
    MigrationBatch Function(String raw)? parse,
  })  : _service = service,
        _collector = collector ?? GoogleMigrationCollector(),
        _parse = parse ?? GoogleAuthParser.parseUri;

  final ImportService _service;
  final GoogleMigrationCollector _collector;
  final MigrationBatch Function(String raw) _parse;

  /// Parses [raw] and merges it, mapping every failure mode onto a
  /// [MigrationScanEvent]. Never throws: a hostile QR is a UI message, not a
  /// crash.
  MigrationScanEvent handleRaw(String raw) {
    final MigrationBatch batch;
    try {
      batch = _parse(raw);
    } catch (_) {
      // Every documented failure (`MalformedMigrationUriException` at the URI /
      // base64 layer, `FormatException` from the wire decoder) and anything
      // unforeseen collapse into ONE outcome on purpose: the cause is derived
      // from secret material and must not be disclosed, and a hostile QR must
      // never take down a live camera session. Nothing is logged.
      return const MigrationMalformedQr();
    }
    return switch (_collector.add(batch)) {
      MigrationAddOutcome.added => _collector.isComplete
          ? MigrationScanComplete(scannedCount, batchSize)
          : MigrationBatchAdded(scannedCount, batchSize),
      MigrationAddOutcome.duplicateIndex => const MigrationDuplicateScan(),
      MigrationAddOutcome.differentBatch => const MigrationDifferentBatch(),
      MigrationAddOutcome.invalidBatch => const MigrationInvalidBatch(),
      MigrationAddOutcome.full => const MigrationScanFull(),
    };
  }

  /// Codes collected so far.
  int get scannedCount => _collector.scannedCount;

  /// Codes the export claims in total, or 0 before the first successful scan.
  int get batchSize => _collector.batchSize;

  /// Whether every code of the export has been scanned.
  bool get isComplete => _collector.isComplete;

  /// Whether nothing has been scanned yet.
  bool get isEmpty => _collector.isEmpty;

  /// Drops everything collected. Called by "Baştan başla" and by the page's
  /// `dispose`.
  void reset() => _collector.reset();

  /// Builds the confirmation preview from what has been scanned, deduplicated
  /// against [existing] (the vault). Side-effect free — the page applies the
  /// result via `VaultCubit.addAll`. Throws `EmptyImportException` when the
  /// scanned codes yielded nothing at all.
  ImportPreview preview({required List<OtpAccount> existing}) =>
      _service.previewParsed(_collector.toParsedImport(), existing: existing);
}
