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
/// Crypto is [BackupFakeCrypto] because libsodium's plugin does not load on the
/// host VM (docs/CRYPTO.md §10); the real primitives are covered in
/// `integration_test/`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/import_export/data/aegis_parser.dart';
import 'package:project_auth/features/import_export/data/twofas_parser.dart';
import 'package:project_auth/features/import_export/domain/backup_service.dart';
import 'package:project_auth/features/import_export/domain/import_exceptions.dart';
import 'package:project_auth/features/import_export/domain/import_models.dart';
import 'package:project_auth/features/import_export/domain/import_service.dart';

import '../../support/fake_crypto.dart';

const _backupPassword = 'Yedek-Parolam-123';

String _fixture(String name) =>
    File('test/fixtures/import/$name').readAsStringSync();

/// Exactly the production wiring from `locator.dart`: parsers injected,
/// `detector`/`keyOf` left at their defaults.
ImportService _service(BackupService backup) =>
    ImportService(backup: backup, parsers: const [AegisParser(), TwoFasParser()]);

int _countOf(ImportPreview p, SkipReason reason) =>
    p.skipped.where((e) => e.reason == reason).length;

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
