/// Faz 5 Patch 2 — `ScanPage` migration modu widget testleri (plan §5/§6, R3).
///
/// `MobileScanner` host VM'de kamera + plugin ister → hiç render EDİLMEZ:
/// `ScanPage.debugScannerBuilder` yer tutucu bir widget döndürür ve verilen
/// `onRaw` geri çağrısı, gerçek bir QR karesinin girdiği yolun ta kendisidir.
/// Migration beyni de (`debugMigration`) enjekte edilir; böylece bu testler
/// W1'in protobuf gövdelerinden bağımsızdır.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/platform/secure_screen.dart';
import 'package:project_auth/features/import_export/domain/import_exceptions.dart';
import 'package:project_auth/features/import_export/domain/import_models.dart';
import 'package:project_auth/features/import_export/domain/import_service.dart';
import 'package:project_auth/features/scan/presentation/migration_scan_controller.dart';
import 'package:project_auth/features/scan/presentation/scan_page.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';

/// Migration QR'ları (içerik önemsiz — parse enjekte edilmiş fake'te).
const _qrA = 'otpauth-migration://offline?data=AAAA';
const _qrB = 'otpauth-migration://offline?data=BBBB';
const _singleToken = 'otpauth://totp/Example:me@example.com?secret=JBSWY3DPEHPK3PXP';

OtpAccount _acc(String name) => OtpAccount(
    secret: 'JBSWY3DPEHPK3PXP', type: OtpType.totp, accountName: name);

class _FakeRepo implements VaultRepository {
  _FakeRepo({this.saveError});

  final Object? saveError;
  List<OtpAccount> stored = [];

  @override
  Future<VaultLoadResult> load() async =>
      VaultLoadResult(accounts: List.of(stored));
  @override
  Future<void> save(List<OtpAccount> accounts) async {
    if (saveError != null) throw saveError!;
    stored = List.of(accounts);
  }

  @override
  Future<void> purgeCorrupted() async {}
}

/// `MigrationScanController` somut sınıf → `implements` ile sahtelenir.
class _FakeMigration implements MigrationScanController {
  _FakeMigration({
    this.script = const {},
    this.previewResult,
    this.previewError,
  });

  /// Ham QR metni → döndürülecek olay.
  final Map<String, MigrationScanEvent> script;
  final ImportPreview? previewResult;
  final Object? previewError;

  final List<String> seen = [];
  int resets = 0;
  int previews = 0;
  List<OtpAccount>? lastExisting;

  @override
  MigrationScanEvent handleRaw(String raw) {
    seen.add(raw);
    return script[raw] ?? const MigrationMalformedQr();
  }

  @override
  ImportPreview preview({required List<OtpAccount> existing}) {
    previews++;
    lastExisting = existing;
    if (previewError != null) throw previewError!;
    return previewResult!;
  }

  @override
  void reset() => resets++;

  @override
  int get scannedCount => seen.length;
  @override
  int get batchSize => 0;
  @override
  bool get isComplete => false;
  @override
  bool get isEmpty => seen.isEmpty;
}

/// Yer tutucu "kamera": her QR için bir düğme. Basmak = o kareyi okumak.
Widget _fakeScanner(BuildContext context, void Function(String raw) onRaw) =>
    Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final raw in const [_qrA, _qrB, _singleToken])
          TextButton(
            onPressed: () => onRaw(raw),
            child: Text('scan:${raw.substring(raw.length - 4)}'),
          ),
      ],
    );

Finder _scan(String suffix) => find.text('scan:$suffix');

/// ScanPage'i alttaki bir sayfadan PUSH eder → `pop` doğal biçimde test edilir.
Future<VaultCubit> _pumpScan(
  WidgetTester tester, {
  required _FakeMigration migration,
  _FakeRepo? repo,
  List<OtpAccount> existing = const [],
  void Function()? onRestart,
}) async {
  final vault = VaultCubit(repo ?? _FakeRepo());
  await vault.load();
  addTearDown(vault.close);
  if (existing.isNotEmpty) await vault.addAll(existing);

  final page = ScanPage(
    debugMigration: migration,
    debugScannerBuilder: _fakeScanner,
    debugRestartCamera: () async => onRestart?.call(),
  );

  await tester.pumpWidget(
    BlocProvider<VaultCubit>.value(
      value: vault,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () => Navigator.of(c)
                  .push(MaterialPageRoute<void>(builder: (_) => page)),
              child: const Text('tarayıcıyı aç'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('tarayıcıyı aç'));
  await tester.pumpAndSettle();
  return vault;
}

void main() {
  testWidgets('migration QR → alt bantta sayaç ve yönerge', (tester) async {
    final migration =
        _FakeMigration(script: const {_qrA: MigrationBatchAdded(1, 3)});
    await _pumpScan(tester, migration: migration);

    // Migration moduna girmeden bant yok.
    expect(find.textContaining('kod tarandı'), findsNothing);

    await tester.tap(_scan('AAAA'));
    await tester.pumpAndSettle();

    expect(find.text('1/3 kod tarandı'), findsOneWidget);
    expect(find.text('Kalan kodları sırayla okut'), findsOneWidget);
    expect(find.text('Bu kadar yeter'), findsOneWidget);
    expect(find.text('Baştan başla'), findsOneWidget);
    expect(find.text('Devam'), findsNothing, reason: 'henüz tamamlanmadı');
    expect(find.text('Google Authenticator kodunu tara'), findsOneWidget);
  });

  testWidgets('tüm kodlar okununca "Devam" öne çıkar', (tester) async {
    final migration =
        _FakeMigration(script: const {_qrA: MigrationScanComplete(3, 3)});
    await _pumpScan(tester, migration: migration);

    await tester.tap(_scan('AAAA'));
    await tester.pumpAndSettle();

    expect(find.text('3/3 kod tarandı'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Devam'), findsOneWidget);
    expect(find.text('Bu kadar yeter'), findsNothing);
    expect(find.text('Kalan kodları sırayla okut'), findsNothing);
  });

  testWidgets('tekrar okunan kod → uyarı, sayaç değişmez', (tester) async {
    final migration = _FakeMigration(script: const {
      _qrA: MigrationBatchAdded(1, 2),
      _qrB: MigrationDuplicateScan(),
    });
    await _pumpScan(tester, migration: migration);

    await tester.tap(_scan('AAAA'));
    await tester.pumpAndSettle();
    await tester.tap(_scan('BBBB'));
    await tester.pump();

    expect(find.text('Bu kod zaten okundu'), findsOneWidget);
    expect(find.text('1/2 kod tarandı'), findsOneWidget);
  });

  testWidgets('bozuk QR → sabit mesaj (neden açıklanmaz)', (tester) async {
    final migration = _FakeMigration(script: const {
      _qrA: MigrationBatchAdded(1, 2),
      _qrB: MigrationMalformedQr(),
    });
    await _pumpScan(tester, migration: migration);

    await tester.tap(_scan('AAAA'));
    await tester.pumpAndSettle();
    await tester.tap(_scan('BBBB'));
    await tester.pump();

    expect(
        find.text('Bu QR bir Google Authenticator aktarım kodu değil ya da bozuk.'),
        findsOneWidget);
    expect(find.text('1/2 kod tarandı'), findsOneWidget);
  });

  testWidgets('kapasite aşımı → "çok fazla hesap" uyarısı', (tester) async {
    final migration = _FakeMigration(script: const {
      _qrA: MigrationBatchAdded(1, 2),
      _qrB: MigrationScanFull(),
    });
    await _pumpScan(tester, migration: migration);

    await tester.tap(_scan('AAAA'));
    await tester.pumpAndSettle();
    await tester.tap(_scan('BBBB'));
    await tester.pump();

    expect(find.text('Bu aktarımda çok fazla hesap var.'), findsOneWidget);
  });

  group('farklı dışa aktarma diyaloğu', () {
    _FakeMigration build() => _FakeMigration(script: const {
          _qrA: MigrationBatchAdded(1, 3),
          _qrB: MigrationDifferentBatch(),
        });

    testWidgets('"Vazgeç" → toplanan kodlar korunur, reset yok', (tester) async {
      final migration = build();
      var restarts = 0;
      await _pumpScan(tester,
          migration: migration, onRestart: () => restarts++);

      await tester.tap(_scan('AAAA'));
      await tester.pumpAndSettle();
      await tester.tap(_scan('BBBB'));
      await tester.pumpAndSettle();

      expect(
          find.text('Bu QR farklı bir dışa aktarmaya ait. Baştan başlansın mı?'),
          findsOneWidget);

      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();

      expect(migration.resets, 0);
      expect(restarts, 0);
      expect(find.text('1/3 kod tarandı'), findsOneWidget);
    });

    testWidgets('"Baştan başla" → reset + kamera yeniden başlatılır',
        (tester) async {
      final migration = build();
      var restarts = 0;
      await _pumpScan(tester,
          migration: migration, onRestart: () => restarts++);

      await tester.tap(_scan('AAAA'));
      await tester.pumpAndSettle();
      await tester.tap(_scan('BBBB'));
      await tester.pumpAndSettle();
      // Bant düğmesiyle aynı metni taşıyan diyalog aksiyonu (plan §5 metinleri)
      // → tip ile ayrıştır.
      await tester.tap(find.widgetWithText(FilledButton, 'Baştan başla'));
      await tester.pumpAndSettle();

      expect(migration.resets, 1);
      // mobile_scanner 7.4 NO_DUPLICATES belleği yalnız stop()/start() ile
      // temizlenir → aynı QR yeniden okunabilsin diye kamera restart ŞART.
      expect(restarts, 1);
      expect(find.textContaining('kod tarandı'), findsNothing);
    });
  });

  testWidgets('"Bu kadar yeter" → uyarı → önizleme (kısmi aktarım)',
      (tester) async {
    final migration = _FakeMigration(
      script: const {_qrA: MigrationBatchAdded(1, 3)},
      previewResult: ImportPreview(
        source: ImportSource.googleAuth,
        toAdd: [_acc('a'), _acc('b')],
        skipped: const [
          SkippedEntry(reason: SkipReason.alreadyInVault, label: 'GitHub (me)'),
        ],
      ),
    );
    await _pumpScan(tester, migration: migration);

    await tester.tap(_scan('AAAA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bu kadar yeter'));
    await tester.pumpAndSettle();

    expect(find.text('Yalnız taradığın kodlardaki hesaplar aktarılacak.'),
        findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Devam'));
    await tester.pumpAndSettle();

    expect(migration.previews, 1);
    expect(find.text('Google Authenticator'), findsOneWidget);
    expect(find.text('1/3 kod'), findsOneWidget);
    expect(find.text('2 token içe aktarılacak'), findsOneWidget);
    expect(find.text('1 zaten var'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'İçe aktar'), findsOneWidget);
  });

  testWidgets('"Bu kadar yeter" → "Vazgeç" → önizleme AÇILMAZ', (tester) async {
    final migration = _FakeMigration(
      script: const {_qrA: MigrationBatchAdded(1, 3)},
      previewResult:
          const ImportPreview(source: ImportSource.googleAuth, toAdd: []),
    );
    await _pumpScan(tester, migration: migration);

    await tester.tap(_scan('AAAA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bu kadar yeter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();

    expect(migration.previews, 0);
    expect(find.text('1/3 kod tarandı'), findsOneWidget);
  });

  testWidgets('onay → VaultCubit.addAll + SnackBar + sayfa kapanır',
      (tester) async {
    final toAdd = [_acc('a'), _acc('b')];
    final repo = _FakeRepo();
    final migration = _FakeMigration(
      script: const {_qrA: MigrationScanComplete(1, 1)},
      previewResult:
          ImportPreview(source: ImportSource.googleAuth, toAdd: toAdd),
    );
    final vault =
        await _pumpScan(tester, migration: migration, repo: repo);

    await tester.tap(_scan('AAAA'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Devam'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'İçe aktar'));
    await tester.pumpAndSettle();

    expect(vault.state.accounts.map((e) => e.id), toAdd.map((e) => e.id));
    expect(repo.stored.length, 2, reason: 'addAll persist etmeli');
    expect(find.text('2 token eklendi'), findsOneWidget);
    expect(find.text('tarayıcıyı aç'), findsOneWidget, reason: 'sayfa kapandı');
    expect(migration.resets, greaterThanOrEqualTo(1),
        reason: 'secret\'lar bellekte kalmamalı');
  });

  testWidgets('addAll hata verirse sayfa KAPANMAZ, hata gösterilir',
      (tester) async {
    final repo = _FakeRepo(saveError: StateError('disk dolu'));
    final migration = _FakeMigration(
      script: const {_qrA: MigrationScanComplete(1, 1)},
      previewResult:
          ImportPreview(source: ImportSource.googleAuth, toAdd: [_acc('a')]),
    );
    await _pumpScan(tester, migration: migration, repo: repo);

    await tester.tap(_scan('AAAA'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Devam'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'İçe aktar'));
    await tester.pumpAndSettle();

    expect(find.text('Tokenlar kaydedilemedi — tekrar dene.'), findsOneWidget);
    expect(find.text('tarayıcıyı aç'), findsNothing, reason: 'sayfa açık kalmalı');
  });

  testWidgets('boş sonuç → önizlemeye GEÇMEZ, uyarı gösterir', (tester) async {
    final migration = _FakeMigration(
      script: const {_qrA: MigrationScanComplete(1, 1)},
      previewError: const EmptyImportException(),
    );
    await _pumpScan(tester, migration: migration);

    await tester.tap(_scan('AAAA'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Devam'));
    await tester.pump();

    expect(find.text('Bu kodlarda içe aktarılacak token bulunamadı.'),
        findsOneWidget);
    expect(find.text('1/1 kod tarandı'), findsOneWidget);
  });

  testWidgets('önizleme SECRET göstermez', (tester) async {
    final migration = _FakeMigration(
      script: const {_qrA: MigrationScanComplete(1, 1)},
      previewResult: ImportPreview(
        source: ImportSource.googleAuth,
        toAdd: [_acc('a')],
        skipped: const [
          SkippedEntry(reason: SkipReason.invalidSecret, label: 'Bozuk (x)'),
        ],
      ),
    );
    await _pumpScan(tester, migration: migration);

    await tester.tap(_scan('AAAA'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Devam'));
    await tester.pumpAndSettle();

    // `_acc` hepsini bu secret'la kurar; önizleme yalnız issuer/hesap gösterir.
    expect(find.textContaining('JBSWY3DP'), findsNothing);
    expect(find.text('1 token içe aktarılacak'), findsOneWidget);
  });

  testWidgets('vault\'taki mevcut tokenlar dedupe girdisi olarak geçer',
      (tester) async {
    final existing = [_acc('mevcut')];
    final migration = _FakeMigration(
      script: const {_qrA: MigrationScanComplete(1, 1)},
      previewResult:
          const ImportPreview(source: ImportSource.googleAuth, toAdd: []),
    );
    await _pumpScan(tester, migration: migration, existing: existing);

    await tester.tap(_scan('AAAA'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Devam'));
    await tester.pumpAndSettle();

    expect(migration.lastExisting?.map((a) => a.id), existing.map((a) => a.id));
    // toAdd boş → onay pasif.
    final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'İçe aktar'));
    expect(button.onPressed, isNull);
  });

  group('tek token yolu korunur', () {
    testWidgets('otpauth:// QR → vault.add + sayfa kapanır', (tester) async {
      final repo = _FakeRepo();
      final vault = await _pumpScan(tester,
          migration: _FakeMigration(), repo: repo);

      await tester.tap(_scan('3PXP'));
      await tester.pumpAndSettle();

      expect(vault.state.accounts.length, 1);
      expect(find.text('tarayıcıyı aç'), findsOneWidget);
    });

    testWidgets('migration yarıdayken tek token QR EKLENMEZ', (tester) async {
      final migration =
          _FakeMigration(script: const {_qrA: MigrationBatchAdded(1, 3)});
      final vault = await _pumpScan(tester, migration: migration);

      await tester.tap(_scan('AAAA'));
      await tester.pumpAndSettle();
      await tester.tap(_scan('3PXP'));
      await tester.pumpAndSettle();

      expect(vault.state.accounts, isEmpty);
      expect(find.text('1/3 kod tarandı'), findsOneWidget);
    });
  });

  group('güvenlik', () {
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

    testWidgets('ScanPage hassas ekran korumasını açar/kapatır', (tester) async {
      final migration = _FakeMigration();
      await _pumpScan(tester, migration: migration);

      expect(calls, ['enable']);
      expect(SecureScreen.holderCount, 1);

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pumpAndSettle();

      expect(calls, ['enable', 'disable']);
      expect(SecureScreen.holderCount, 0);
      expect(migration.resets, 1,
          reason: 'dispose toplanan secret\'ları düşürmeli');
    });
  });
}
