/// Phase 5 Patch 1 — wiring smoke test: the REAL `ImportService` with the REAL
/// parsers, the REAL `detectSource` and the REAL `dedupeKey`, driven by the
/// fixture files.
///
/// Every other test in this folder isolates one layer behind stubs, so a
/// mis-wired DI (`ImportService(backup: ...)` with no parsers, a stubbed
/// detector left in place) would still leave them all green. This one only
/// passes when the pieces are actually connected the way `locator.dart`
/// connects them.
///
/// Phase 5 Patch 2 adds the Google Authenticator path to the same idea: the
/// REAL `GoogleAuthParser`, the REAL `GoogleMigrationCollector` and the REAL
/// `MigrationScanController` feeding the REAL `ImportService.previewParsed`.
/// Only the camera is missing — `handleRaw` takes the string a `MobileScanner`
/// would have produced.
///
/// Crypto is [BackupFakeCrypto] because libsodium's plugin does not load on the
/// host VM (docs/CRYPTO.md §10); the real primitives are covered in
/// `integration_test/`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/import_export/data/aegis_parser.dart';
import 'package:project_auth/features/import_export/data/twofas_parser.dart';
import 'package:project_auth/features/import_export/domain/backup_service.dart';
import 'package:project_auth/features/import_export/domain/import_exceptions.dart';
import 'package:project_auth/features/import_export/domain/import_models.dart';
import 'package:project_auth/features/import_export/domain/import_service.dart';
import 'package:project_auth/features/import_export/domain/dedupe.dart';
import 'package:project_auth/features/scan/presentation/migration_scan_controller.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/domain/catalog_repository.dart';
import 'package:project_auth/features/vault/domain/issuer_catalog.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';

import '../../support/fake_crypto.dart';
import '../../support/protobuf_encoder.dart';

const _backupPassword = 'Yedek-Parolam-123';

String _fixture(String name) =>
    File('test/fixtures/import/$name').readAsStringSync();

/// Exactly the production wiring from `locator.dart`: parsers injected,
/// `detector`/`keyOf` left at their defaults.
ImportService _service(BackupService backup) =>
    ImportService(backup: backup, parsers: const [AegisParser(), TwoFasParser()]);

int _countOf(ImportPreview p, SkipReason reason) =>
    p.skipped.where((e) => e.reason == reason).length;

/// Plan §1 golden vector A, percent-encoded: one TOTP entry
/// (`Example` / `alice@example.com`, secret bytes `48656c6c6f21deadbeef`),
/// `batch_size` 1. Pinned as a literal on purpose — if the encoder below and
/// the decoder ever drifted together, this string would still catch it.
const _vectorAUri = 'otpauth-migration://offline?data='
    'Ci4KCkhlbGxvId6tvu8SEWFsaWNlQGV4YW1wbGUuY29tGgdFeGFtcGxlIAEoATACEAEYASAAKAA%3D';

/// A TOTP `OtpParameters` body: SHA1 / 6 digits, the shape Google exports.
Uint8List _entry({
  required String secretHex,
  required String name,
  required String issuer,
}) =>
    encodeOtpParameters(
      secret: fromHex(secretHex),
      name: name,
      issuer: issuer,
      algorithm: ProtoAlgorithm.sha1,
      digits: ProtoDigits.six,
      type: ProtoOtpType.totp,
    );

/// One QR of a multi-code export: [entries] stamped with the batch coordinates.
String _batchUri({
  required List<Uint8List> entries,
  required int batchIndex,
  required int batchSize,
  required int batchId,
}) =>
    migrationUri(encodeMigrationPayload(
      entries: entries,
      batchSize: batchSize,
      batchIndex: batchIndex,
      batchId: batchId,
    ));

void main() {
  late BackupService backup;
  late ImportService service;

  setUp(() {
    backup = BackupService(BackupFakeCrypto());
    service = _service(backup);
  });

  group('Aegis (plain v1) end to end', () {
    test('detected and parsed through the real parser + real dedupe key',
        () async {
      final raw = _fixture('aegis_plain_v1.json');
      expect(service.detect(raw), ImportSource.aegis);

      final preview = await service.preview(raw: raw, existing: const []);

      expect(preview.source, ImportSource.aegis);
      // 5 entries in the file; #2 is the same token re-exported with different
      // secret formatting, which only the real Base32-canonicalizing dedupe key
      // collapses.
      expect(preview.addCount, 4);
      expect(_countOf(preview, SkipReason.duplicateInFile), 1);
      expect(preview.skippedCount, 0);
      expect(
        preview.toAdd.map((a) => a.accountName),
        containsAll(<String>['alice@example.com', 'bob@example.com']),
      );
      // Phase 5 Patch 3: `db.groups` reached the preview as tags.
      expect(preview.toAdd.first.tags, ['Work']);
    });

    test('a token already in the vault is reported as alreadyInVault',
        () async {
      final raw = _fixture('aegis_plain_v1.json');
      final existing = <OtpAccount>[
        OtpAccount(
          secret: 'JBSWY3DPEHPK3PXP',
          type: OtpType.totp,
          issuer: 'GitHub',
          accountName: 'alice@example.com',
        ),
      ];

      final preview = await service.preview(raw: raw, existing: existing);

      // Both GitHub rows (the second differs only in secret formatting and
      // issuer casing) collapse onto the vault entry.
      expect(_countOf(preview, SkipReason.alreadyInVault), 2);
      expect(preview.addCount, 3);
    });
  });

  // --- Audit A2: the catalog rewrite the vault applies must also drive dedupe ---
  group('issuer canonicalization end to end', () {
    /// The production catalog shape: an alias row ("github.com") plus the
    /// canonical row, both resolving to the name `VaultCubit` stores.
    ImportService catalogService() => ImportService(
          backup: backup,
          parsers: const [AegisParser(), TwoFasParser()],
          // Exactly `locator.dart`: a resolver returning the canonicalizer
          // bound to the current catalog snapshot.
          canonicalizeResolver: () => canonicalizerFor(IssuerCatalog(const [
                CatalogService(
                    id: '1', name: 'GitHub', issuer: 'github.com', logoUrl: null),
                CatalogService(
                    id: '2', name: 'GitHub', issuer: null, logoUrl: null),
              ])),
        );

    /// A minimal but real Aegis v1 export whose issuer is the ALIAS form.
    String aliasFile() => jsonEncode({
          'version': 1,
          'header': {'slots': null, 'params': null},
          'db': {
            'version': 3,
            'entries': [
              {
                'type': 'totp',
                'uuid': '3f1a6c2e-0b41-4a9d-9d1e-8f0b2c7a5d10',
                'name': 'alice@example.com',
                'issuer': 'github.com',
                'info': {
                  'secret': 'JBSWY3DPEHPK3PXP',
                  'algo': 'SHA1',
                  'digits': 6,
                  'period': 30,
                },
              },
            ],
          },
        });

    OtpAccount inVault(String issuer) => OtpAccount(
          secret: 'JBSWY3DPEHPK3PXP',
          type: OtpType.totp,
          issuer: issuer,
          accountName: 'alice@example.com',
        );

    test('vault "GitHub" + file "github.com" → alreadyInVault', () async {
      final preview = await catalogService()
          .preview(raw: aliasFile(), existing: [inVault('GitHub')]);

      expect(preview.addCount, 0);
      expect(_countOf(preview, SkipReason.alreadyInVault), 1,
          reason: 'VaultCubit stores "GitHub"; a re-import of the alias file '
              'must not add a second copy');
    });

    test('the same file WITHOUT the catalog wiring duplicates the token '
        '(the bug this guards)', () async {
      final preview =
          await service.preview(raw: aliasFile(), existing: [inVault('GitHub')]);
      expect(preview.addCount, 1);
    });

    test('vault "github.com" + file "GitHub" → alreadyInVault (both sides are '
        'canonicalized)', () async {
      final preview = await catalogService().preview(
          raw: _fixture('aegis_plain_v1.json'),
          existing: [inVault('github.com')]);
      expect(_countOf(preview, SkipReason.alreadyInVault), 2,
          reason: 'both GitHub rows of the fixture collapse onto the vault row');
    });

    test('an entry the catalog does not know keeps its issuer verbatim',
        () async {
      final preview = await catalogService()
          .preview(raw: _fixture('aegis_plain_v1.json'), existing: const []);
      // "ACME" is absent from the catalog and a null issuer has nothing to
      // match — both must come through exactly as the file wrote them.
      expect(preview.toAdd.map((a) => a.issuer),
          containsAll(<String?>['GitHub', 'ACME', null]));
    });
  });

  group('2FAS (schema v4) end to end', () {
    test('detected and parsed through the real parser', () async {
      final raw = _fixture('twofas_v4.json');
      expect(service.detect(raw), ImportSource.twofas);

      final preview = await service.preview(raw: raw, existing: const []);

      expect(preview.source, ImportSource.twofas);
      // 5 services; the MD5 one is unsupported.
      expect(preview.addCount, 4);
      expect(preview.skippedCount, 1);
      expect(preview.duplicateCount, 0);
      // Phase 5 Patch 3: root `groups` + `groupId` reached the preview as tags.
      expect(preview.toAdd.map((a) => a.tags),
          [['Work'], <String>[], ['Kişisel'], <String>[]]);
    });
  });

  group('export → import round trip', () {
    final accounts = <OtpAccount>[
      OtpAccount(
        secret: 'JBSWY3DPEHPK3PXP',
        type: OtpType.totp,
        issuer: 'GitHub',
        accountName: 'alice@example.com',
      ),
      OtpAccount(
        secret: 'KRSXG5CTMVRXEZLU',
        type: OtpType.totp,
        issuer: 'ACME',
        accountName: 'bob@example.com',
      ),
    ];

    test('our own backup is detected, decrypted and fully restorable',
        () async {
      final raw =
          await backup.export(accounts: accounts, password: _backupPassword);
      expect(service.detect(raw), ImportSource.projectauthBackup);

      final preview = await service.preview(
        raw: raw,
        existing: const [],
        backupPassword: _backupPassword,
      );

      expect(preview.addCount, accounts.length);
      expect(preview.skipped, isEmpty);
      expect(preview.toAdd.map((a) => a.id),
          unorderedEquals(accounts.map((a) => a.id)));
    });

    test('restoring into the same vault adds nothing', () async {
      final raw =
          await backup.export(accounts: accounts, password: _backupPassword);

      final preview = await service.preview(
        raw: raw,
        existing: accounts,
        backupPassword: _backupPassword,
      );

      expect(preview.addCount, 0);
      expect(_countOf(preview, SkipReason.alreadyInVault), accounts.length);
    });

    test('a wrong backup password fails as WrongBackupPasswordException',
        () async {
      final raw =
          await backup.export(accounts: accounts, password: _backupPassword);

      await expectLater(
        service.preview(
          raw: raw,
          existing: const [],
          backupPassword: 'Baska-Parola-999',
        ),
        throwsA(isA<WrongBackupPasswordException>()),
      );
    });
  });

  group('Google Authenticator migration end to end', () {
    // Same three tokens throughout: #3 repeats #1 (identical secret, issuer and
    // account name) the way a user who exported an already-duplicated vault
    // gets it back.
    const aliceSecretHex = '48656c6c6f21deadbeef'; // Base32 JBSWY3DPEHPK3PXP
    const bobSecretHex = '4b6579732d666f722d626f62';

    late MigrationScanController controller;

    setUp(() => controller = MigrationScanController(service));

    List<String> threeCodes({int batchId = 77}) {
      final alice =
          _entry(secretHex: aliceSecretHex, name: 'alice@example.com', issuer: 'Example');
      final bob = _entry(secretHex: bobSecretHex, name: 'bob@example.com', issuer: 'ACME');
      final aliceAgain =
          _entry(secretHex: aliceSecretHex, name: 'alice@example.com', issuer: 'Example');
      return <String>[
        for (final (index, entry) in <Uint8List>[alice, bob, aliceAgain].indexed)
          _batchUri(
            entries: <Uint8List>[entry],
            batchIndex: index,
            batchSize: 3,
            batchId: batchId,
          ),
      ];
    }

    test('a single-code export goes from raw QR string to a one-token preview',
        () {
      // Real parser: URI → base64 → protobuf → OtpAccount, no stubs anywhere.
      expect(controller.handleRaw(_vectorAUri), const MigrationScanComplete(1, 1));
      expect(controller.isComplete, isTrue);

      final preview = controller.preview(existing: const []);

      expect(preview.source, ImportSource.googleAuth);
      expect(preview.addCount, 1);
      expect(preview.skipped, isEmpty);
      final account = preview.toAdd.single;
      expect(account.secret, 'JBSWY3DPEHPK3PXP');
      expect(account.issuer, 'Example');
      expect(account.accountName, 'alice@example.com');
      expect(account.type, OtpType.totp);
      expect(account.digits, 6);
      expect(account.period, 30);
    });

    test('three codes scanned out of order stitch back together, and the '
        'repeated token collapses through the real dedupe key', () {
      final codes = threeCodes();

      // Deliberately 2 → 0 → 1: the collector orders by batchIndex, not by the
      // order the camera happened to see the codes in.
      expect(controller.handleRaw(codes[2]), const MigrationBatchAdded(1, 3));
      expect(controller.handleRaw(codes[0]), const MigrationBatchAdded(2, 3));
      expect(controller.handleRaw(codes[1]), const MigrationScanComplete(3, 3));
      expect(controller.isComplete, isTrue);

      final preview = controller.preview(existing: const []);

      expect(preview.source, ImportSource.googleAuth);
      expect(preview.addCount, 2);
      expect(_countOf(preview, SkipReason.duplicateInFile), 1);
      expect(preview.skippedCount, 0);
      // Ordered by batchIndex: alice (0) then bob (1); the repeat (2) is the
      // one dropped, so the survivor list is the first-seen pair.
      expect(preview.toAdd.map((a) => a.accountName),
          <String>['alice@example.com', 'bob@example.com']);
    });

    test('a token already in the vault is reported as alreadyInVault', () {
      final codes = threeCodes();
      for (final code in codes) {
        controller.handleRaw(code);
      }
      // Same token as code #1/#3, stored with the loose formatting the vault
      // accepts (lowercase issuer, spaced secret) — only the real dedupe key
      // canonicalizes both sides onto one match.
      final existing = <OtpAccount>[
        OtpAccount(
          secret: 'jbsw y3dp ehpk 3pxp',
          type: OtpType.totp,
          issuer: 'example',
          accountName: 'Alice@Example.com',
        ),
      ];

      final preview = controller.preview(existing: existing);

      // Both copies of alice hit the vault entry; only bob is left to add.
      expect(_countOf(preview, SkipReason.alreadyInVault), 2);
      expect(_countOf(preview, SkipReason.duplicateInFile), 0);
      expect(preview.addCount, 1);
      expect(preview.toAdd.single.accountName, 'bob@example.com');
    });

    test('a code from another export is refused and leaves the collected '
        'codes untouched', () {
      final codes = threeCodes();
      expect(controller.handleRaw(codes[0]), const MigrationBatchAdded(1, 3));
      expect(controller.handleRaw(codes[1]), const MigrationBatchAdded(2, 3));

      // Same coordinates, different batch_id: a QR from a second export.
      final foreign = _batchUri(
        entries: <Uint8List>[
          _entry(
              secretHex: '4f7468657220657870',
              name: 'mallory@example.com',
              issuer: 'Other'),
        ],
        batchIndex: 2,
        batchSize: 3,
        batchId: 78,
      );

      expect(controller.handleRaw(foreign), const MigrationDifferentBatch());
      expect(controller.scannedCount, 2);
      expect(controller.isComplete, isFalse);

      // Nothing merged: the partial preview is exactly the two codes scanned
      // before the foreign one, and mallory is nowhere in it.
      final preview = controller.preview(existing: const []);
      expect(preview.addCount, 2);
      expect(preview.toAdd.map((a) => a.accountName),
          <String>['alice@example.com', 'bob@example.com']);
      expect(preview.skipped, isEmpty);

      // The rightful third code still completes the export afterwards.
      expect(controller.handleRaw(codes[2]), const MigrationScanComplete(3, 3));
    });
  });

  // --- Phase 5 Patch 3: a grouped import survives the whole loop ---
  group('tags end to end (grouped Aegis → vault → backup → re-import)', () {
    test('group labels reach the vault and come back out of our own backup',
        () async {
      // 1. A real grouped Aegis file, through the real parser + real dedupe.
      final raw = _fixture('aegis_plain_v1.json');
      final preview = await service.preview(raw: raw, existing: const []);
      expect(preview.addCount, 4);
      expect(preview.toAdd.map((a) => a.tags), [
        ['Work'], // GitHub / alice
        ['Work', 'Kişisel'], // bob, two groups in file order
        <String>[], // ACME, unknown group uuid → silently untagged
        <String>[], // the ungrouped row
      ]);

      // 2. Confirming the preview: ONE addAll, exactly like the import page.
      final repo = _MemoryRepo();
      final cubit = VaultCubit(repo);
      await cubit.load();
      await cubit.addAll(preview.toAdd);

      expect(cubit.state.accounts, hasLength(4));
      expect(cubit.allTags, ['Work', 'Kişisel']); // usage count descending
      expect(repo.saveCount, 1, reason: 'tek toplu yazma');

      // 3. The user renames a tag: every carrier is rewritten in one save.
      await cubit.renameTag('Work', 'Ofis');
      expect(cubit.allTags, ['Ofis', 'Kişisel']);
      expect(repo.saveCount, 2);

      // 4. Export the vault and read it back through the REAL backup path.
      final backupJson = await backup.export(
          accounts: cubit.state.accounts, password: _backupPassword);
      expect(service.detect(backupJson), ImportSource.projectauthBackup);

      final restored = await service.preview(
        raw: backupJson,
        existing: const [],
        backupPassword: _backupPassword,
      );

      // 5. The tags survived the round trip, renames included.
      expect(restored.addCount, 4);
      expect(restored.toAdd.map((a) => a.tags), [
        ['Ofis'],
        ['Ofis', 'Kişisel'],
        <String>[],
        <String>[],
      ]);
      expect(restored.toAdd, cubit.state.accounts,
          reason: 'tags are in props → full record equality');
    });

    test('re-importing the SAME tokens under different groups adds nothing '
        '(tags are not identity — K5)', () async {
      // The vault holds the Aegis tokens with the tags the user ended up with.
      final parsed = await service.preview(
          raw: _fixture('aegis_plain_v1.json'), existing: const []);
      final vault = [
        for (final a in parsed.toAdd) a.copyWith(tags: const ['Arşiv']),
      ];

      // The very same file re-imported: every token is already in the vault
      // even though its groups now say something else.
      final again = await service.preview(
          raw: _fixture('aegis_plain_v1.json'), existing: vault);

      expect(again.addCount, 0);
      expect(_countOf(again, SkipReason.alreadyInVault), 5);
    });
  });

  test('an unrecognized JSON object is refused before any parser runs',
      () async {
    const raw = '{"totallyUnknown": true}';
    expect(service.detect(raw), ImportSource.unknown);
    await expectLater(
      service.preview(raw: raw, existing: const []),
      throwsA(isA<UnsupportedImportFormatException>()),
    );
  });

  test('text that is not JSON is refused before fingerprinting', () {
    expect(() => service.detect('not json at all'),
        throwsA(isA<MalformedImportFileException>()));
  });

  test('a structurally broken Aegis file is refused by the real parser',
      () async {
    // Valid JSON and fingerprinted as Aegis, but `db.entries` is an object —
    // only the real parser (not the detector) can reject this.
    final raw = _fixture('malformed.json');
    expect(service.detect(raw), ImportSource.aegis);
    await expectLater(
      service.preview(raw: raw, existing: const []),
      throwsA(isA<MalformedImportFileException>()),
    );
  });

  test('an encrypted Aegis vault names its source', () async {
    final raw = _fixture('aegis_encrypted_slots.json');
    // Sanity: the fixture really is JSON we can fingerprint.
    expect(jsonDecode(raw), isA<Map<String, dynamic>>());
    await expectLater(
      service.preview(raw: raw, existing: const []),
      throwsA(isA<EncryptedSourceException>()
          .having((e) => e.source, 'source', ImportSource.aegis)),
    );
  });
}

/// Minimal in-memory vault repository — the import→vault hop needs persistence
/// but not encryption (the crypto path has its own tests).
class _MemoryRepo implements VaultRepository {
  List<OtpAccount> stored = const [];
  int saveCount = 0;

  @override
  Future<VaultLoadResult> load() async =>
      VaultLoadResult(accounts: List.of(stored));

  @override
  Future<void> save(List<OtpAccount> accounts) async {
    saveCount++;
    stored = List.of(accounts);
  }

  @override
  Future<void> purgeCorrupted() async {}
}
