/// Faz 5 Patch 1 (plan §4.6 / D6) — Import/Export ekranları SecureScreen
/// korumasını AÇAR/KAPATIR.
///
/// ImportPage token listesi + yedek parolası, ExportPage yedek parolası gösterir
/// → ikisi de hassas ekran. `test/features/auth/secure_screen_pages_test.dart`
/// kalıbı: mount'ta native `enable`, unmount'ta `disable` (ref-count 1 → 0).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/crypto_service.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/platform/secure_screen.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/import_export/domain/backup_service.dart';
import 'package:project_auth/features/import_export/domain/file_port.dart';
import 'package:project_auth/features/import_export/domain/import_models.dart';
import 'package:project_auth/features/import_export/domain/import_service.dart';
import 'package:project_auth/features/import_export/presentation/pages/export_page.dart';
import 'package:project_auth/features/import_export/presentation/pages/import_page.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';

class _FakeLock extends Cubit<VaultLockState> implements VaultLockCubit {
  _FakeLock() : super(const VaultLockState.unlocked());
  @override
  noSuchMethod(Invocation i) {}
}

class _EmptyRepo implements VaultRepository {
  @override
  Future<VaultLoadResult> load() async => const VaultLoadResult(accounts: []);
  @override
  Future<void> save(List<OtpAccount> accounts) async {}
  @override
  Future<void> purgeCorrupted() async {}
}

class _NoopDocuments implements DocumentPort {
  const _NoopDocuments();
  @override
  Future<PickedDocument?> pickJson({required int maxBytes}) async => null;
  @override
  Future<bool> saveJson({
    required String fileName,
    required Uint8List bytes,
  }) async =>
      false;
}

class _NoopImportService implements ImportService {
  const _NoopImportService();
  @override
  ImportSource detect(String raw) => ImportSource.unknown;
  @override
  Future<ImportPreview> preview({
    required String raw,
    required List<OtpAccount> existing,
    String? backupPassword,
  }) async =>
      const ImportPreview(source: ImportSource.unknown, toAdd: []);
  @override
  BackupService get backup => throw UnimplementedError();
  @override
  List<ImportParser> get parsers => const [];
}

class _NoopBackup implements BackupService {
  const _NoopBackup();
  @override
  Future<String> export({
    required List<OtpAccount> accounts,
    required String password,
    DateTime? now,
  }) async =>
      '{}';
  @override
  Future<List<OtpAccount>> import({
    required String json,
    required String password,
  }) async =>
      const [];
  @override
  CryptoService get crypto => throw UnimplementedError();
}

void main() {
  const channel = MethodChannel('dev.mustafakara.project_auth/secure_screen');
  late List<String> calls;

  setUp(() {
    calls = [];
    SecureScreen.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    SecureScreen.debugReset();
  });

  Future<void> expectProtected(WidgetTester tester, Widget page) async {
    final lock = _FakeLock();
    addTearDown(lock.close);
    final vault = VaultCubit(_EmptyRepo());
    await vault.load();
    addTearDown(vault.close);

    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<VaultLockCubit>.value(value: lock),
        BlocProvider<VaultCubit>.value(value: vault),
      ],
      child: MaterialApp(home: page),
    ));
    await tester.pump();
    expect(calls, ['enable'], reason: 'mount → koruma açılmalı');
    expect(SecureScreen.holderCount, 1);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(calls, ['enable', 'disable'], reason: 'unmount → koruma kapanmalı');
    expect(SecureScreen.holderCount, 0);
  }

  testWidgets('ImportPage (token listesi + yedek parolası) korunur',
      (tester) async {
    await expectProtected(
      tester,
      const ImportPage(
        service: _NoopImportService(),
        documents: _NoopDocuments(),
      ),
    );
  });

  testWidgets('ExportPage (yedek parolası) korunur', (tester) async {
    await expectProtected(
      tester,
      const ExportPage(backup: _NoopBackup(), documents: _NoopDocuments()),
    );
  });
}
