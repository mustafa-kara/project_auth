/// Faz 5 Patch 1 — ExportPage widget testleri (plan §5.4).
///
/// `BackupService` gövdesi W2 tarafından doldurulana kadar sözleşme sınıfı
/// `implements` ile sahtelenir → sayfa bugün sözleşmeye karşı doğrulanır.
/// libsodium, file_picker ve DI gerekmez.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/crypto_service.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/ui/widgets/password_strength_bar.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/import_export/domain/backup_service.dart';
import 'package:project_auth/features/import_export/domain/file_port.dart';
import 'package:project_auth/features/import_export/presentation/pages/export_page.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';

// --- Fakes ---

const _goodPassword = 'Yedek-Parolam-123';

OtpAccount _acc(String name) => OtpAccount(
    secret: 'JBSWY3DPEHPK3PXP', type: OtpType.totp, accountName: name);

class _FakeRepo implements VaultRepository {
  _FakeRepo([this.stored = const []]);
  List<OtpAccount> stored;
  @override
  Future<VaultLoadResult> load() async =>
      VaultLoadResult(accounts: List.of(stored));
  @override
  Future<void> save(List<OtpAccount> accounts) async =>
      stored = List.of(accounts);
  @override
  Future<void> purgeCorrupted() async {}
}

class _FakeLock extends Cubit<VaultLockState> implements VaultLockCubit {
  _FakeLock() : super(const VaultLockState.unlocked());
  int begins = 0;
  int ends = 0;

  /// Gerçek cubit gibi: begin ile açılır, end ile kapanır (dispose testi bunu okur).
  bool _active = false;

  @override
  bool get systemFileFlowActive => _active;

  @override
  void beginSystemFileFlow({Duration budget = const Duration(minutes: 2)}) {
    begins++;
    _active = true;
  }

  @override
  void endSystemFileFlow() {
    ends++;
    _active = false;
  }

  @override
  noSuchMethod(Invocation i) {}
}

class _FakeBackup implements BackupService {
  _FakeBackup({this.exportError});
  final Object? exportError;

  int exportCount = 0;
  String? lastPassword;
  int? lastAccountCount;

  @override
  Future<String> export({
    required List<OtpAccount> accounts,
    required String password,
    DateTime? now,
  }) async {
    exportCount++;
    lastPassword = password;
    lastAccountCount = accounts.length;
    if (exportError != null) throw exportError!;
    return '{"format":"projectauth-backup","version":1}';
  }

  @override
  Future<List<OtpAccount>> import({
    required String json,
    required String password,
  }) async =>
      const [];

  /// ExportPage never restores; an explicit throw keeps a wrong call loud
  /// instead of silently returning an empty vault.
  @override
  Future<BackupPayload> importDetailed({
    required String json,
    required String password,
  }) async =>
      throw UnimplementedError();

  @override
  CryptoService get crypto => throw UnimplementedError();
}

class _FakeDocuments implements DocumentPort {
  _FakeDocuments({this.saveResult = true, this.gate});
  final bool saveResult;

  /// Doluysa `saveJson` bu completer tamamlanana kadar ASILI kalır — kaydetme
  /// diyaloğu hâlâ ekrandayken sayfanın sökülmesini simüle eder.
  final Completer<bool>? gate;

  int saveCount = 0;
  String? lastFileName;
  Uint8List? lastBytes;

  @override
  Future<PickedDocument?> pickJson({required int maxBytes}) async => null;

  @override
  Future<bool> saveJson({
    required String fileName,
    required Uint8List bytes,
  }) async {
    saveCount++;
    lastFileName = fileName;
    lastBytes = bytes;
    final open = gate;
    if (open != null) return open.future;
    return saveResult;
  }

  // Faz 5 Patch 3 — bu ekran görüntü seçmez; sözleşme gereği override edilir.
  @override
  Future<PickedImage?> pickImage({required int maxBytes}) async => null;

  @override
  Future<void> clearPickerCache() async {}
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required _FakeBackup backup,
  required _FakeDocuments documents,
  required _FakeLock lock,
  List<OtpAccount> accounts = const [],
}) async {
  final vault = VaultCubit(_FakeRepo(accounts));
  await vault.load();
  addTearDown(vault.close);
  await tester.pumpWidget(
    MultiBlocProvider(
      providers: [
        BlocProvider<VaultLockCubit>.value(value: lock),
        BlocProvider<VaultCubit>.value(value: vault),
      ],
      child: MaterialApp(
        home: ExportPage(backup: backup, documents: documents),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _fillForm(
  WidgetTester tester, {
  required String password,
  String? confirm,
}) async {
  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(0), password);
  await tester.pump();
  await tester.enterText(fields.at(1), confirm ?? password);
  await tester.pump();
}

void main() {
  late _FakeLock lock;

  setUp(() => lock = _FakeLock());
  tearDown(() => lock.close());

  testWidgets('boş vault → EmptyState, form/CTA yok', (tester) async {
    await _pumpPage(
      tester,
      backup: _FakeBackup(),
      documents: _FakeDocuments(),
      lock: lock,
    );

    expect(find.text('Yedeklenecek token yok'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Yedek oluştur'), findsNothing);
  });

  testWidgets('dolu vault → form + parola gücü göstergesi', (tester) async {
    await _pumpPage(
      tester,
      backup: _FakeBackup(),
      documents: _FakeDocuments(),
      lock: lock,
      accounts: [_acc('a')],
    );

    expect(find.text('Şifreli yedek al'), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(find.byType(PasswordStrengthBar), findsNothing,
        reason: 'parola boşken gösterge gizli');

    await tester.enterText(find.byType(TextFormField).at(0), 'kisa');
    await tester.pump();
    expect(find.byType(PasswordStrengthBar), findsOneWidget);
  });

  testWidgets('C7: güç göstergesi tema renklerini kullanır + tek semantik düğüm',
      (tester) async {
    await _pumpPage(
      tester,
      backup: _FakeBackup(),
      documents: _FakeDocuments(),
      lock: lock,
      accounts: [_acc('a')],
    );

    // "Orta" seviye: politikayı karşılar (12+ karakter, 3 sınıf) ama
    // 16 karakter + 4 sınıf eşiğine ulaşmaz.
    await tester.enterText(find.byType(TextFormField).at(0), 'Parolam12345');
    await tester.pump();

    final scheme = Theme.of(tester.element(find.byType(PasswordStrengthBar)))
        .colorScheme;
    final bar = tester.widget<LinearProgressIndicator>(
      find.descendant(
        of: find.byType(PasswordStrengthBar),
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    expect(bar.color, scheme.tertiary,
        reason: 'sabit Colors.orange değil, şema rolü');

    // `excludeSemantics: true` → alt düğümler (metin, ilerleme çubuğu) ayrı
    // düğüm üretmez; ekran okuyucu tek bir "Parola gücü: Orta" duyurur.
    final node = tester.getSemantics(find.byType(PasswordStrengthBar));
    expect(node.label, 'Parola gücü: Orta');
    var children = 0;
    node.visitChildren((_) {
      children++;
      return true;
    });
    expect(children, 0, reason: 'alt semantik düğümler dışlanmalı');
  });

  testWidgets('zayıf parola → politika hatası, export ÇAĞRILMAZ', (tester) async {
    final backup = _FakeBackup();
    final docs = _FakeDocuments();
    await _pumpPage(
      tester,
      backup: backup,
      documents: docs,
      lock: lock,
      accounts: [_acc('a')],
    );

    await _fillForm(tester, password: 'kisa123');
    await tester.tap(find.widgetWithText(FilledButton, 'Yedek oluştur'));
    await tester.pumpAndSettle();

    expect(backup.exportCount, 0);
    expect(docs.saveCount, 0);
    expect(find.textContaining('en az 12 karakter'), findsOneWidget);
  });

  testWidgets('eşleşmeyen tekrar → hata, export ÇAĞRILMAZ', (tester) async {
    final backup = _FakeBackup();
    await _pumpPage(
      tester,
      backup: backup,
      documents: _FakeDocuments(),
      lock: lock,
      accounts: [_acc('a')],
    );

    await _fillForm(tester,
        password: _goodPassword, confirm: 'Baska-Parola-999');
    await tester.tap(find.widgetWithText(FilledButton, 'Yedek oluştur'));
    await tester.pumpAndSettle();

    expect(backup.exportCount, 0);
    expect(find.text('Parolalar eşleşmiyor'), findsOneWidget);
  });

  testWidgets('geçerli parola → export + saveJson + kilit muafiyeti + uyarı '
      'diyaloğu', (tester) async {
    final backup = _FakeBackup();
    final docs = _FakeDocuments();
    await _pumpPage(
      tester,
      backup: backup,
      documents: docs,
      lock: lock,
      accounts: [_acc('a'), _acc('b')],
    );

    await _fillForm(tester, password: _goodPassword);
    await tester.tap(find.widgetWithText(FilledButton, 'Yedek oluştur'));
    await tester.pumpAndSettle();

    expect(backup.exportCount, 1);
    expect(backup.lastPassword, _goodPassword);
    expect(backup.lastAccountCount, 2);

    expect(docs.saveCount, 1);
    expect(docs.lastFileName, startsWith('projectauth-backup-'));
    expect(docs.lastFileName, endsWith('.json'));
    expect(utf8.decode(docs.lastBytes!), contains('projectauth-backup'));

    // Kaydetme diyaloğu da app'i arka plana atar → muafiyet açılıp KAPANMALI.
    expect(lock.begins, 1);
    expect(lock.ends, 1);

    expect(find.text('Yedek oluşturuldu'), findsOneWidget);
    expect(
      find.textContaining('master parolan ya da kurtarma anahtarın bu '
          'dosyayı açmaz'),
      findsOneWidget,
    );
  });

  testWidgets('kaydetme iptal edilirse başarı diyaloğu GÖSTERİLMEZ',
      (tester) async {
    final backup = _FakeBackup();
    await _pumpPage(
      tester,
      backup: backup,
      documents: _FakeDocuments(saveResult: false),
      lock: lock,
      accounts: [_acc('a')],
    );

    await _fillForm(tester, password: _goodPassword);
    await tester.tap(find.widgetWithText(FilledButton, 'Yedek oluştur'));
    await tester.pumpAndSettle();

    expect(backup.exportCount, 1);
    expect(find.text('Yedek oluşturuldu'), findsNothing);
    expect(lock.ends, 1, reason: 'iptalde de muafiyet kapanmalı');
  });

  testWidgets('export patlarsa jenerik hata + muafiyet kapalı (secret sızmaz)',
      (tester) async {
    final backup = _FakeBackup(exportError: StateError('crypto patladı'));
    final docs = _FakeDocuments();
    await _pumpPage(
      tester,
      backup: backup,
      documents: docs,
      lock: lock,
      accounts: [_acc('a')],
    );

    await _fillForm(tester, password: _goodPassword);
    await tester.tap(find.widgetWithText(FilledButton, 'Yedek oluştur'));
    await tester.pumpAndSettle();

    expect(docs.saveCount, 0);
    expect(find.text('Yedek oluşturulamadı — tekrar dene.'), findsOneWidget);
    expect(find.textContaining('crypto patladı'), findsNothing,
        reason: 'teknik detay UI\'a sızmamalı');
  });

  testWidgets('kaydetme diyaloğu AÇIKKEN sayfa sökülürse muafiyet dispose\'ta '
      'kapanır', (tester) async {
    final gate = Completer<bool>();
    final docs = _FakeDocuments(gate: gate);
    await _pumpPage(
      tester,
      backup: _FakeBackup(),
      documents: docs,
      lock: lock,
      accounts: [_acc('a')],
    );

    await _fillForm(tester, password: _goodPassword);
    await tester.tap(find.widgetWithText(FilledButton, 'Yedek oluştur'));
    await tester.pump(); // diyalog açıldı, sonuç HENÜZ yok
    await tester.pump();
    expect(docs.saveCount, 1);
    expect(lock.begins, 1);
    expect(lock.ends, 0);
    expect(lock.systemFileFlowActive, isTrue);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();

    expect(lock.ends, 1, reason: 'dispose muafiyeti kapatmalı');
    expect(lock.systemFileFlowActive, isFalse);

    gate.complete(false); // asılı future'ı temizle
    await tester.pumpAndSettle();
  });

  test('yedek dosya adı tarih damgalı', () {
    expect(backupFileName(DateTime.utc(2026, 9, 2)),
        'projectauth-backup-20260902.json');
    expect(backupFileName(DateTime.utc(2026, 12, 31)),
        'projectauth-backup-20261231.json');
  });
}
