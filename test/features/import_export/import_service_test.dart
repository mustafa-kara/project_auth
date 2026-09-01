/// Phase 5 Patch 1 — ImportService: file-level guards, format routing, backup
/// decryption and duplicate detection.
///
/// The real `detectSource`/`dedupeKey` (W1) are injected as stubs here so this
/// layer can be verified independently of the source parsers; production wiring
/// passes neither and gets the real ones.
library;


import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/import_export/domain/backup_service.dart';
import 'package:project_auth/features/import_export/domain/import_exceptions.dart';
import 'package:project_auth/features/import_export/domain/import_models.dart';
import 'package:project_auth/features/import_export/domain/import_service.dart';

import '../../support/fake_crypto.dart';

const _password = 'Yedek-Parola12!';
const _secretA = 'JBSWY3DPEHPK3PXP';
const _secretB = 'KRSXG5CTMVRXEZLU';

OtpAccount _acc(String name, {String? issuer, String? secret, String? id}) =>
    OtpAccount(
      id: id,
      secret: secret ?? _secretA,
      type: OtpType.totp,
      accountName: name,
      issuer: issuer,
    );

/// Stand-in for `dedupeKey` (W1): issuer + account + secret, without the Base32
/// canonicalization this layer does not care about. Top-level so it stays
/// sendable to the parse isolate.
String _testKey(OtpAccount a) =>
    '${(a.issuer ?? '').toLowerCase()}|${a.accountName.toLowerCase()}|${a.secret}';

/// Parser stub. Returns fixed results, or throws a fixed error.
class _StubParser implements ImportParser {
  @override
  final ImportSource source;
  final List<OtpAccount> accounts;
  final List<SkippedEntry> skipped;
  final Object? error;

  const _StubParser(
    this.source, {
    this.accounts = const <OtpAccount>[],
    this.skipped = const <SkippedEntry>[],
    this.error,
  });

  @override
  ParsedImport parse(Map<String, dynamic> json) {
    if (error != null) throw error!;
    return ParsedImport(source: source, accounts: accounts, skipped: skipped);
  }
}

void main() {
  late BackupService backup;

  setUp(() => backup = BackupService(BackupFakeCrypto()));

  ImportService service({
    List<ImportParser>? parsers,
    ImportSource detected = ImportSource.aegis,
  }) =>
      ImportService(
        parsers: parsers,
        backup: backup,
        detector: (_) => detected,
        keyOf: _testKey,
      );

  const anyJson = '{"db":{},"header":{}}';

  group('decodeRoot / detect', () {
    test('detect returns the detector verdict', () {
      expect(service(detected: ImportSource.twofas).detect(anyJson),
          ImportSource.twofas);
    });

    test('unknown is returned, not thrown — the caller decides', () {
      expect(service(detected: ImportSource.unknown).detect(anyJson),
          ImportSource.unknown);
    });

    test('not JSON → MalformedImportFileException', () {
      expect(() => service().detect('<xml/>'),
          throwsA(isA<MalformedImportFileException>()));
    });

    test('a JSON array root → MalformedImportFileException', () {
      expect(() => service().detect('[1,2,3]'),
          throwsA(isA<MalformedImportFileException>()));
    });

    test('a JSON scalar root → MalformedImportFileException', () {
      expect(() => service().detect('42'),
          throwsA(isA<MalformedImportFileException>()));
    });

    test('over maxBytes → ImportFileTooLargeException (before decoding)', () {
      final huge = '{"pad":"${'x' * (ImportService.maxBytes + 10)}"}';
      expect(() => service().detect(huge),
          throwsA(isA<ImportFileTooLargeException>()));
    });

    test('the size limit counts UTF-8 bytes, not UTF-16 code units', () {
      // 'ş' is 2 bytes in UTF-8 but a single code unit — a file just under the
      // limit by code units can still be over it by bytes.
      final padding = 'ş' * (ImportService.maxBytes ~/ 2);
      expect(() => service().detect('{"pad":"$padding"}'),
          throwsA(isA<ImportFileTooLargeException>()));
    });

    test('preview enforces the same size limit', () async {
      final huge = '{"pad":"${'x' * (ImportService.maxBytes + 10)}"}';
      await expectLater(
        service().preview(raw: huge, existing: const []),
        throwsA(isA<ImportFileTooLargeException>()),
      );
    });
  });

  group('preview — routing', () {
    test('unknown format → UnsupportedImportFormatException', () async {
      await expectLater(
        service(detected: ImportSource.unknown)
            .preview(raw: anyJson, existing: const []),
        throwsA(isA<UnsupportedImportFormatException>()),
      );
    });

    test('a detected format with no parser wired → UnsupportedImportFormat',
        () async {
      await expectLater(
        service(parsers: const []).preview(raw: anyJson, existing: const []),
        throwsA(isA<UnsupportedImportFormatException>()),
      );
    });

    test('picks the parser whose source matches the detector', () async {
      final preview = await service(
        detected: ImportSource.twofas,
        parsers: [
          _StubParser(ImportSource.aegis, accounts: [_acc('aegis')]),
          _StubParser(ImportSource.twofas, accounts: [_acc('twofas')]),
        ],
      ).preview(raw: anyJson, existing: const []);

      expect(preview.source, ImportSource.twofas);
      expect(preview.toAdd.single.accountName, 'twofas');
    });

    test('a parser error propagates out of the parse isolate', () async {
      await expectLater(
        service(parsers: [
          const _StubParser(ImportSource.aegis,
              error: EncryptedSourceException(ImportSource.aegis)),
        ]).preview(raw: anyJson, existing: const []),
        throwsA(isA<EncryptedSourceException>()),
      );
    });

    test('zero parsed accounts AND zero skips → EmptyImportException', () async {
      await expectLater(
        service(parsers: [const _StubParser(ImportSource.aegis)])
            .preview(raw: anyJson, existing: const []),
        throwsA(isA<EmptyImportException>()),
      );
    });

    test('zero parsed accounts but skips present → preview with the skips',
        () async {
      final preview = await service(parsers: [
        const _StubParser(
          ImportSource.aegis,
          skipped: [SkippedEntry(reason: SkipReason.unsupportedType)],
        ),
      ]).preview(raw: anyJson, existing: const []);
      expect(preview.toAdd, isEmpty);
      expect(preview.skipped, hasLength(1));
    });

    test('the parser\'s own skipped entries survive into the preview', () async {
      final preview = await service(parsers: [
        _StubParser(
          ImportSource.aegis,
          accounts: [_acc('a')],
          skipped: const [
            SkippedEntry(reason: SkipReason.unsupportedType, label: 'Yandex'),
          ],
        ),
      ]).preview(raw: anyJson, existing: const []);

      expect(preview.addCount, 1);
      expect(preview.skippedCount, 1);
      expect(preview.duplicateCount, 0);
      expect(preview.skipped.single.label, 'Yandex');
    });
  });

  group('dedupe', () {
    ImportPreview run(List<OtpAccount> parsed, List<OtpAccount> existing,
            {ImportSource source = ImportSource.aegis,
            List<SkippedEntry> skipped = const []}) =>
        ImportService.dedupeSync(
          ParsedImport(source: source, accounts: parsed, skipped: skipped),
          existing: existing,
          keyOf: _testKey,
        );

    test('an account already in the vault → alreadyInVault', () {
      final preview = run([_acc('a', issuer: 'GitHub')],
          [_acc('a', issuer: 'GitHub')]);
      expect(preview.toAdd, isEmpty);
      expect(preview.skipped.single.reason, SkipReason.alreadyInVault);
      expect(preview.skipped.single.label, 'GitHub (a)');
      expect(preview.duplicateCount, 1);
      expect(preview.skippedCount, 0);
    });

    test('a repeat inside the file → duplicateInFile, first wins', () {
      final preview = run([_acc('a'), _acc('a')], const []);
      expect(preview.addCount, 1);
      expect(preview.skipped.single.reason, SkipReason.duplicateInFile);
    });

    test('the comparison is case-insensitive on issuer and account name', () {
      final preview =
          run([_acc('A', issuer: 'GITHUB')], [_acc('a', issuer: 'github')]);
      expect(preview.toAdd, isEmpty);
    });

    test('a different secret is a different account', () {
      final preview = run([_acc('a', secret: _secretB)], [_acc('a')]);
      expect(preview.addCount, 1);
    });

    test('an all-duplicate file is NOT empty — the preview still renders', () {
      final preview = run([_acc('a')], [_acc('a')]);
      expect(preview.addCount, 0);
      expect(preview.duplicateCount, 1);
    });

    test('a truly empty parse result → EmptyImportException', () {
      expect(() => run(const [], const []),
          throwsA(isA<EmptyImportException>()));
    });

    test('0 accounts but skipped entries → preview, NOT EmptyImportException',
        () {
      // Every entry was dropped by the parser. Telling the user WHICH ones and
      // why beats a bare "nothing to import" (review follow-up). `toAdd` is
      // empty, so the UI keeps the confirm button disabled.
      final preview = run(
        const [],
        const [],
        skipped: const [
          SkippedEntry(reason: SkipReason.unsupportedType, label: 'Mystery'),
          SkippedEntry(reason: SkipReason.invalidSecret, label: 'Broken'),
        ],
      );
      expect(preview.toAdd, isEmpty);
      expect(preview.skipped, hasLength(2));
      expect(preview.skippedCount, 2);
      expect(preview.duplicateCount, 0);
    });

    test('parser skips are counted separately from duplicates', () {
      final preview = run(
        [_acc('a'), _acc('b')],
        [_acc('a')],
        skipped: const [SkippedEntry(reason: SkipReason.invalidSecret)],
      );
      expect(preview.addCount, 1);
      expect(preview.duplicateCount, 1);
      expect(preview.skippedCount, 1);
    });

    test('id collisions only count for our own backups', () {
      final existing = _acc('renamed', issuer: 'New');
      final incoming = _acc('original', issuer: 'Old', id: existing.id);

      // Foreign source: ids are freshly generated, so only the key matters.
      expect(run([incoming], [existing], source: ImportSource.aegis).addCount, 1);
      // Our backup preserves ids → the same id is the same token.
      final backupRun =
          run([incoming], [existing], source: ImportSource.projectauthBackup);
      expect(backupRun.addCount, 0);
      expect(backupRun.skipped.single.reason, SkipReason.alreadyInVault);
    });

    test('a repeated id inside a backup file → duplicateInFile', () {
      final a = _acc('a', secret: _secretA, id: 'fixed-id');
      final b = _acc('b', secret: _secretB, id: 'fixed-id');
      final preview =
          run([a, b], const [], source: ImportSource.projectauthBackup);
      expect(preview.addCount, 1);
      expect(preview.skipped.single.reason, SkipReason.duplicateInFile);
    });

    test('the returned lists are unmodifiable', () {
      final preview = run([_acc('a')], const []);
      expect(() => preview.toAdd.add(_acc('b')), throwsUnsupportedError);
      expect(
          () => preview.skipped
              .add(const SkippedEntry(reason: SkipReason.invalidFields)),
          throwsUnsupportedError);
    });
  });

  group('parseAndDedupeSync', () {
    test('parses and deduplicates in one synchronous pass', () {
      final preview = ImportService.parseAndDedupeSync(
        root: const {},
        source: ImportSource.aegis,
        parsers: [
          _StubParser(ImportSource.aegis, accounts: [_acc('a'), _acc('b')]),
        ],
        existing: [_acc('b')],
        keyOf: _testKey,
      );
      expect(preview.toAdd.single.accountName, 'a');
      expect(preview.duplicateCount, 1);
    });

    test('no matching parser → UnsupportedImportFormatException', () {
      expect(
        () => ImportService.parseAndDedupeSync(
          root: const {},
          source: ImportSource.twofas,
          parsers: [const _StubParser(ImportSource.aegis)],
          existing: const [],
          keyOf: _testKey,
        ),
        throwsA(isA<UnsupportedImportFormatException>()),
      );
    });
  });

  group('preview — our own encrypted backup', () {
    late String backupJson;
    late List<OtpAccount> exported;

    setUp(() async {
      exported = [_acc('a', issuer: 'GitHub'), _acc('b', secret: _secretB)];
      backupJson = await backup.export(accounts: exported, password: _password);
    });

    ImportService backupService() =>
        service(detected: ImportSource.projectauthBackup);

    test('decrypts and previews without any parser wired', () async {
      final preview = await backupService().preview(
        raw: backupJson,
        existing: const [],
        backupPassword: _password,
      );
      expect(preview.source, ImportSource.projectauthBackup);
      expect(preview.toAdd.map((a) => a.accountName), ['a', 'b']);
      expect(preview.toAdd.first.id, exported.first.id,
          reason: 'our own backup preserves ids');
    });

    test('a missing password is a programming error (detect() comes first)',
        () async {
      await expectLater(
        backupService().preview(raw: backupJson, existing: const []),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('an empty password is treated as missing', () async {
      await expectLater(
        backupService()
            .preview(raw: backupJson, existing: const [], backupPassword: ''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a wrong password surfaces as WrongBackupPasswordException', () async {
      await expectLater(
        backupService().preview(
            raw: backupJson,
            existing: const [],
            backupPassword: 'Baska-Parola12!'),
        throwsA(isA<WrongBackupPasswordException>()),
      );
    });

    test('restoring over the same vault reports everything as already present',
        () async {
      final preview = await backupService().preview(
        raw: backupJson,
        existing: exported,
        backupPassword: _password,
      );
      expect(preview.addCount, 0);
      expect(preview.duplicateCount, 2);
    });

    test('a backup of an empty vault → EmptyImportException', () async {
      final empty =
          await backup.export(accounts: const [], password: _password);
      await expectLater(
        backupService()
            .preview(raw: empty, existing: const [], backupPassword: _password),
        throwsA(isA<EmptyImportException>()),
      );
    });
  });
}
