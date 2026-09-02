/// Phase 5 Patch 2 — [GoogleMigrationCollector], the multi-QR merge rules
/// (plan §3).
///
/// A Google Authenticator export can span several QR codes and the user scans
/// them in whatever order the camera happens to catch. The invariant under test
/// throughout: a QR that is not accepted leaves the collector byte-for-byte
/// unchanged, so a stray or hostile code can never corrupt what has already
/// been scanned.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/import_export/domain/google_migration.dart';
import 'package:project_auth/features/import_export/domain/import_models.dart';

const String _secret = 'JBSWY3DPEHPK3PXP';

OtpAccount _account(String name) =>
    OtpAccount(secret: _secret, type: OtpType.totp, accountName: name);

MigrationBatch _batch({
  required int index,
  int size = 1,
  int id = 7,
  int version = 1,
  List<String> names = const ['a'],
  List<SkippedEntry> skipped = const <SkippedEntry>[],
}) => MigrationBatch(
  version: version,
  batchSize: size,
  batchIndex: index,
  batchId: id,
  accounts: names.map(_account).toList(),
  skipped: skipped,
);

/// Names of the accounts a collector would hand to the import pipeline.
List<String> _names(GoogleMigrationCollector collector) =>
    collector.toParsedImport().accounts.map((a) => a.accountName).toList();

void main() {
  group('a fresh collector', () {
    test('starts empty, with no pinned batch', () {
      final collector = GoogleMigrationCollector();
      expect(collector.isEmpty, isTrue);
      expect(collector.isComplete, isFalse);
      expect(collector.scannedCount, 0);
      expect(collector.batchSize, 0);
      expect(collector.batchId, isNull);
    });
  });

  group('single-code export', () {
    test('one batch of one is added and immediately complete', () {
      final collector = GoogleMigrationCollector();
      expect(collector.add(_batch(index: 0)), MigrationAddOutcome.added);
      expect(collector.isEmpty, isFalse);
      expect(collector.isComplete, isTrue);
      expect(collector.scannedCount, 1);
      expect(collector.batchSize, 1);
      expect(collector.batchId, 7);
    });
  });

  group('multi-code export', () {
    test('three codes scanned in order', () {
      final collector = GoogleMigrationCollector();
      for (var i = 0; i < 3; i++) {
        expect(
          collector.add(_batch(index: i, size: 3, names: ['n$i'])),
          MigrationAddOutcome.added,
        );
        expect(collector.scannedCount, i + 1);
        expect(collector.isComplete, i == 2);
      }
      expect(_names(collector), orderedEquals(const ['n0', 'n1', 'n2']));
    });

    test('scan order does not change the merged order', () {
      final collector = GoogleMigrationCollector();
      for (final i in const [2, 0, 1]) {
        expect(
          collector.add(_batch(index: i, size: 3, names: ['n$i'])),
          MigrationAddOutcome.added,
        );
      }
      expect(collector.isComplete, isTrue);
      // Emitted by batchIndex, not by arrival: the preview is stable.
      expect(_names(collector), orderedEquals(const ['n0', 'n1', 'n2']));
    });

    test('a partial scan is a legitimate result', () {
      final collector = GoogleMigrationCollector();
      collector.add(_batch(index: 0, size: 3, names: ['n0']));
      collector.add(_batch(index: 2, size: 3, names: ['n2']));
      expect(collector.isComplete, isFalse);
      expect(collector.scannedCount, 2);
      expect(_names(collector), orderedEquals(const ['n0', 'n2']));
    });

    test('skipped entries are merged in the same batchIndex order', () {
      final collector = GoogleMigrationCollector();
      collector.add(
        _batch(
          index: 1,
          size: 2,
          names: const [],
          skipped: const [
            SkippedEntry(reason: SkipReason.unsupportedType, detail: 'second'),
          ],
        ),
      );
      collector.add(
        _batch(
          index: 0,
          size: 2,
          names: const [],
          skipped: const [
            SkippedEntry(reason: SkipReason.invalidSecret, detail: 'first'),
          ],
        ),
      );
      expect(
        collector.toParsedImport().skipped.map((s) => s.detail),
        orderedEquals(const ['first', 'second']),
      );
    });
  });

  group('duplicateIndex', () {
    test('rescanning the same code changes nothing', () {
      final collector = GoogleMigrationCollector();
      collector.add(_batch(index: 0, size: 2, names: ['first']));
      expect(
        collector.add(_batch(index: 0, size: 2, names: ['other'])),
        MigrationAddOutcome.duplicateIndex,
      );
      expect(collector.scannedCount, 1);
      // The FIRST scan's data is kept — a repeat never overwrites.
      expect(_names(collector), orderedEquals(const ['first']));
    });
  });

  group('differentBatch', () {
    test('a different batchId is refused and merges nothing', () {
      final collector = GoogleMigrationCollector();
      collector.add(_batch(index: 0, size: 2, id: 7, names: ['mine']));
      expect(
        collector.add(_batch(index: 1, size: 2, id: 8, names: ['foreign'])),
        MigrationAddOutcome.differentBatch,
      );
      expect(collector.scannedCount, 1);
      expect(collector.batchId, 7);
      expect(_names(collector), orderedEquals(const ['mine']));
    });

    test('a different batchSize is refused too', () {
      final collector = GoogleMigrationCollector();
      collector.add(_batch(index: 0, size: 2, id: 7));
      expect(
        collector.add(_batch(index: 1, size: 3, id: 7)),
        MigrationAddOutcome.differentBatch,
      );
      expect(collector.batchSize, 2);
      expect(collector.scannedCount, 1);
    });

    test('a foreign code reusing an already scanned index reads as a different '
        'export, not a duplicate', () {
      final collector = GoogleMigrationCollector();
      collector.add(_batch(index: 0, size: 2, id: 7));
      expect(
        collector.add(_batch(index: 0, size: 2, id: 99)),
        MigrationAddOutcome.differentBatch,
      );
    });
  });

  group('invalidBatch', () {
    test('a batchSize outside 1..maxBatchSize is refused', () {
      final collector = GoogleMigrationCollector();
      for (final size in [0, -1, GoogleMigrationCollector.maxBatchSize + 1]) {
        expect(
          collector.add(_batch(index: 0, size: size)),
          MigrationAddOutcome.invalidBatch,
          reason: 'batchSize $size',
        );
      }
      expect(collector.isEmpty, isTrue);
    });

    test('the maxBatchSize boundary itself is accepted', () {
      final collector = GoogleMigrationCollector();
      expect(
        collector.add(
          _batch(index: 0, size: GoogleMigrationCollector.maxBatchSize),
        ),
        MigrationAddOutcome.added,
      );
    });

    test('a batchIndex outside 0..batchSize-1 is refused', () {
      final collector = GoogleMigrationCollector();
      for (final index in const [-1, 3, 99]) {
        expect(
          collector.add(_batch(index: index, size: 3)),
          MigrationAddOutcome.invalidBatch,
          reason: 'batchIndex $index',
        );
      }
      expect(collector.isEmpty, isTrue);
    });

    test('coordinates are judged before any comparison with prior state', () {
      final collector = GoogleMigrationCollector();
      collector.add(_batch(index: 0, size: 2, id: 7));
      // Self-inconsistent AND from another export: the self-inconsistency wins,
      // because "start over?" is the wrong question for a malformed code.
      expect(
        collector.add(_batch(index: 9, size: 2, id: 99)),
        MigrationAddOutcome.invalidBatch,
      );
      expect(collector.scannedCount, 1);
    });
  });

  group('batchId edge cases', () {
    test('batchId 0 is a real id, not "unset"', () {
      final collector = GoogleMigrationCollector();
      expect(
        collector.add(_batch(index: 0, size: 2, id: 0)),
        MigrationAddOutcome.added,
      );
      expect(collector.batchId, 0);
      // A second code of the SAME export still merges …
      expect(
        collector.add(_batch(index: 1, size: 2, id: 0)),
        MigrationAddOutcome.added,
      );
      expect(collector.isComplete, isTrue);
    });

    test('a nonzero id is refused against a pinned id of 0', () {
      final collector = GoogleMigrationCollector();
      collector.add(_batch(index: 0, size: 2, id: 0));
      expect(
        collector.add(_batch(index: 1, size: 2, id: 1)),
        MigrationAddOutcome.differentBatch,
      );
    });

    test('a negative batchId is a legitimate id', () {
      final collector = GoogleMigrationCollector();
      expect(
        collector.add(_batch(index: 0, size: 2, id: -2)),
        MigrationAddOutcome.added,
      );
      expect(collector.batchId, -2);
      expect(
        collector.add(_batch(index: 1, size: 2, id: -2)),
        MigrationAddOutcome.added,
      );
      expect(collector.scannedCount, 2);
    });
  });

  group('full', () {
    test('a batch that would exceed maxAccounts is refused whole', () {
      final collector = GoogleMigrationCollector();
      final many = List<String>.generate(
        GoogleMigrationCollector.maxAccounts,
        (i) => 'n$i',
      );
      expect(
        collector.add(_batch(index: 0, size: 2, names: many)),
        MigrationAddOutcome.added,
      );
      expect(
        collector.add(_batch(index: 1, size: 2, names: const ['one more'])),
        MigrationAddOutcome.full,
      );
      // Nothing partially merged.
      expect(collector.scannedCount, 1);
      expect(
        collector.toParsedImport().accounts,
        hasLength(GoogleMigrationCollector.maxAccounts),
      );
    });

    test('skipped entries count toward the cap too', () {
      // A hostile export can be nothing but unmappable entries: they are not
      // tokens, but the preview renders one eager row per skip.
      final collector = GoogleMigrationCollector();
      final manySkipped = List<SkippedEntry>.generate(
        GoogleMigrationCollector.maxAccounts,
        (i) => SkippedEntry(reason: SkipReason.invalidFields, label: 's$i'),
      );
      expect(
        collector.add(
          _batch(index: 0, size: 2, names: const [], skipped: manySkipped),
        ),
        MigrationAddOutcome.added,
      );
      expect(
        collector.add(_batch(index: 1, size: 2, names: const ['one more'])),
        MigrationAddOutcome.full,
      );
      expect(collector.scannedCount, 1);
    });

    test('accounts and skipped entries share one budget', () {
      final collector = GoogleMigrationCollector();
      final half = GoogleMigrationCollector.maxAccounts ~/ 2;
      expect(
        collector.add(
          _batch(
            index: 0,
            size: 2,
            names: List<String>.generate(half, (i) => 'a$i'),
            skipped: List<SkippedEntry>.generate(
              half,
              (i) =>
                  SkippedEntry(reason: SkipReason.invalidFields, label: 's$i'),
            ),
          ),
        ),
        MigrationAddOutcome.added,
      );
      expect(
        collector.add(_batch(index: 1, size: 2, names: const ['extra'])),
        MigrationAddOutcome.full,
      );
    });

    test('landing exactly on maxAccounts is allowed', () {
      final collector = GoogleMigrationCollector();
      final half = GoogleMigrationCollector.maxAccounts ~/ 2;
      collector.add(
        _batch(
          index: 0,
          size: 2,
          names: List<String>.generate(half, (i) => 'a$i'),
        ),
      );
      expect(
        collector.add(
          _batch(
            index: 1,
            size: 2,
            names: List<String>.generate(half, (i) => 'b$i'),
          ),
        ),
        MigrationAddOutcome.added,
      );
    });
  });

  group('toParsedImport', () {
    test('is tagged googleAuth — the source that never comes from a file', () {
      final collector = GoogleMigrationCollector();
      collector.add(_batch(index: 0));
      expect(collector.toParsedImport().source, ImportSource.googleAuth);
    });

    test('an empty collector yields an empty ParsedImport, not an error', () {
      final parsed = GoogleMigrationCollector().toParsedImport();
      expect(parsed.source, ImportSource.googleAuth);
      expect(parsed.accounts, isEmpty);
      expect(parsed.skipped, isEmpty);
    });

    test('is a snapshot: mutating the result does not touch the collector', () {
      final collector = GoogleMigrationCollector();
      collector.add(_batch(index: 0, names: ['a']));
      collector.toParsedImport().accounts.add(_account('injected'));
      expect(_names(collector), orderedEquals(const ['a']));
    });
  });

  group('reset', () {
    test('drops the accounts and unpins the batch', () {
      final collector = GoogleMigrationCollector();
      collector.add(_batch(index: 0, size: 2, id: 7));
      collector.reset();

      expect(collector.isEmpty, isTrue);
      expect(collector.isComplete, isFalse);
      expect(collector.scannedCount, 0);
      expect(collector.batchSize, 0);
      expect(collector.batchId, isNull);
      expect(collector.toParsedImport().accounts, isEmpty);
    });

    test('after reset a previously foreign export is accepted', () {
      final collector = GoogleMigrationCollector();
      collector.add(_batch(index: 0, size: 2, id: 7));
      expect(
        collector.add(_batch(index: 1, size: 3, id: 99)),
        MigrationAddOutcome.differentBatch,
      );

      collector.reset();
      expect(
        collector.add(_batch(index: 1, size: 3, id: 99)),
        MigrationAddOutcome.added,
      );
      expect(collector.batchId, 99);
      expect(collector.batchSize, 3);
    });
  });

  group('limits', () {
    test('the declared ceilings are the ones the plan fixed', () {
      expect(GoogleMigrationCollector.maxBatchSize, 16);
      expect(GoogleMigrationCollector.maxAccounts, 1024);
    });
  });
}
