/// Faz 5 Patch 2 — `MigrationScanController` birim testleri (plan §5, R3).
///
/// Kamera YOK, protobuf YOK: parse fonksiyonu ve collector enjekte edilir, böylece
/// olay akışının TAMAMI (her `MigrationAddOutcome` + bozuk QR yolu) W1'in gerçek
/// gövdelerinden bağımsız doğrulanır.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/import_export/domain/backup_service.dart';
import 'package:project_auth/features/import_export/domain/google_migration.dart';
import 'package:project_auth/features/import_export/domain/import_exceptions.dart';
import 'package:project_auth/features/import_export/domain/import_models.dart';
import 'package:project_auth/features/import_export/domain/import_service.dart';
import 'package:project_auth/features/scan/presentation/migration_scan_controller.dart';

OtpAccount _acc(String name) => OtpAccount(
    secret: 'JBSWY3DPEHPK3PXP', type: OtpType.totp, accountName: name);

MigrationBatch _batch({int index = 0, int size = 1}) => MigrationBatch(
      version: 1,
      batchSize: size,
      batchIndex: index,
      batchId: 7,
      accounts: [_acc('a$index')],
    );

/// `GoogleMigrationCollector` somut bir sınıf; Dart'ta somut sınıf da
/// `implements` edilebilir → W1'in gövdesi beklenmeden davranış sabitlenir.
class _FakeCollector implements GoogleMigrationCollector {
  MigrationAddOutcome outcome = MigrationAddOutcome.added;
  int scanned = 0;
  int size = 0;
  bool complete = false;
  int resets = 0;
  final List<MigrationBatch> added = [];
  ParsedImport parsed =
      const ParsedImport(source: ImportSource.googleAuth, accounts: []);

  @override
  MigrationAddOutcome add(MigrationBatch batch) {
    added.add(batch);
    return outcome;
  }

  @override
  int? get batchId => 7;
  @override
  int get batchSize => size;
  @override
  int get scannedCount => scanned;
  @override
  bool get isComplete => complete;
  @override
  bool get isEmpty => scanned == 0;
  @override
  ParsedImport toParsedImport() => parsed;
  @override
  void reset() => resets++;
}

class _FakeService implements ImportService {
  _FakeService({this.result, this.error});

  final ImportPreview? result;
  final Object? error;

  ParsedImport? lastParsed;
  List<OtpAccount>? lastExisting;

  @override
  ImportPreview previewParsed(
    ParsedImport parsed, {
    required List<OtpAccount> existing,
  }) {
    lastParsed = parsed;
    lastExisting = existing;
    if (error != null) throw error!;
    return result!;
  }

  @override
  ImportSource detect(String raw) => throw UnimplementedError();
  @override
  Future<ImportPreview> preview({
    required String raw,
    required List<OtpAccount> existing,
    String? backupPassword,
  }) =>
      throw UnimplementedError();
  @override
  BackupService get backup => throw UnimplementedError();
  @override
  List<ImportParser> get parsers => const [];
}

void main() {
  late _FakeCollector collector;
  late _FakeService service;

  setUp(() {
    collector = _FakeCollector();
    service = _FakeService(
        result: const ImportPreview(source: ImportSource.googleAuth, toAdd: []));
  });

  MigrationScanController build({
    MigrationBatch Function(String raw)? parse,
  }) =>
      MigrationScanController(
        service,
        collector: collector,
        parse: parse ?? (_) => _batch(),
      );

  group('bozuk QR', () {
    test('MalformedMigrationUriException → MigrationMalformedQr, add çağrılmaz',
        () {
      final c = build(
          parse: (_) => throw const MalformedMigrationUriException('nope'));

      expect(c.handleRaw('otpauth-migration://offline?data=xx'),
          const MigrationMalformedQr());
      expect(collector.added, isEmpty, reason: 'bozuk QR state\'i kirletmemeli');
    });

    test('decoder FormatException da aynı olaya düşer (neden gizlenir)', () {
      final c = build(parse: (_) => throw const FormatException('wire type 3'));
      expect(c.handleRaw('x'), const MigrationMalformedQr());
    });

    test('beklenmeyen hata bile fırlatılmaz — kamera oturumu çökmez', () {
      final c = build(parse: (_) => throw ArgumentError('bug'));
      expect(c.handleRaw('x'), const MigrationMalformedQr());
    });
  });

  group('outcome → event', () {
    test('added + eksik → MigrationBatchAdded(sayaçlarla)', () {
      final c = build();
      collector
        ..outcome = MigrationAddOutcome.added
        ..scanned = 1
        ..size = 3
        ..complete = false;

      expect(c.handleRaw('x'), const MigrationBatchAdded(1, 3));
    });

    test('added + tamam → MigrationScanComplete', () {
      final c = build();
      collector
        ..outcome = MigrationAddOutcome.added
        ..scanned = 3
        ..size = 3
        ..complete = true;

      expect(c.handleRaw('x'), const MigrationScanComplete(3, 3));
    });

    test('duplicateIndex → MigrationDuplicateScan', () {
      final c = build();
      collector.outcome = MigrationAddOutcome.duplicateIndex;
      expect(c.handleRaw('x'), const MigrationDuplicateScan());
    });

    test('differentBatch → MigrationDifferentBatch', () {
      final c = build();
      collector.outcome = MigrationAddOutcome.differentBatch;
      expect(c.handleRaw('x'), const MigrationDifferentBatch());
    });

    test('invalidBatch → MigrationInvalidBatch', () {
      final c = build();
      collector.outcome = MigrationAddOutcome.invalidBatch;
      expect(c.handleRaw('x'), const MigrationInvalidBatch());
    });

    test('full → MigrationScanFull', () {
      final c = build();
      collector.outcome = MigrationAddOutcome.full;
      expect(c.handleRaw('x'), const MigrationScanFull());
    });

    test('parse edilen batch collector\'a AYNEN geçer', () {
      final c = build(parse: (_) => _batch(index: 2, size: 3));
      c.handleRaw('x');
      expect(collector.added.single.batchIndex, 2);
      expect(collector.added.single.batchSize, 3);
    });
  });

  group('olay eşitliği (Equatable)', () {
    test('aynı sayaçlar eşit, farklı tip eşit değil', () {
      expect(const MigrationBatchAdded(1, 3), const MigrationBatchAdded(1, 3));
      expect(const MigrationBatchAdded(1, 3),
          isNot(const MigrationBatchAdded(2, 3)));
      expect(const MigrationBatchAdded(3, 3),
          isNot(const MigrationScanComplete(3, 3)));
      expect(const MigrationDuplicateScan(), const MigrationDuplicateScan());
    });
  });

  group('durum ve önizleme', () {
    test('getter\'lar collector\'a delege eder', () {
      final c = build();
      collector
        ..scanned = 2
        ..size = 4
        ..complete = false;

      expect(c.scannedCount, 2);
      expect(c.batchSize, 4);
      expect(c.isComplete, isFalse);
      expect(c.isEmpty, isFalse);
    });

    test('reset collector\'ı sıfırlar', () {
      build().reset();
      expect(collector.resets, 1);
    });

    test('preview: collector çıktısı + vault listesi servise geçer', () {
      final vault = [_acc('mevcut')];
      collector.parsed = ParsedImport(
        source: ImportSource.googleAuth,
        accounts: [_acc('yeni')],
      );
      final expected =
          ImportPreview(source: ImportSource.googleAuth, toAdd: [_acc('yeni')]);
      service = _FakeService(result: expected);

      final preview = build().preview(existing: vault);

      expect(identical(preview, expected), isTrue);
      expect(service.lastParsed, same(collector.parsed));
      expect(service.lastExisting, same(vault));
    });

    test('hiç token yoksa EmptyImportException yukarı çıkar (UI karar verir)',
        () {
      service = _FakeService(error: const EmptyImportException());
      expect(() => build().preview(existing: const []),
          throwsA(isA<EmptyImportException>()));
    });
  });
}
