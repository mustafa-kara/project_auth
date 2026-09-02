/// Faz 5 Patch 2 — `ScanPage` migration modu widget testleri (plan §5/§6, R3).
///
/// `MobileScanner` host VM'de kamera + plugin ister → hiç render EDİLMEZ:
/// `ScanPage.debugScannerBuilder` yer tutucu bir widget döndürür ve verilen
/// `onDetect` geri çağrısı, gerçek bir kamera karesinin girdiği yolun ta
/// kendisidir (`BarcodeCapture` → `_onDetect`).
/// Migration beyni de (`debugMigration`) enjekte edilir; böylece bu testler
/// W1'in protobuf gövdelerinden bağımsızdır.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
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

/// Tek kameradan gelen bir kare: istenen ham değerleri taşıyan `BarcodeCapture`.
BarcodeCapture _capture(List<String> raws) => BarcodeCapture(
      barcodes: [for (final raw in raws) Barcode(rawValue: raw)],
    );

/// Yer tutucu "kamera": her QR için bir düğme. Basmak = o kareyi okumak.
/// `scan:iki` TEK karede iki migration QR'ı yayınlar (kullanıcı iki kodu yan
/// yana tutmuş).
Widget _fakeScanner(
        BuildContext context, void Function(BarcodeCapture capture) onDetect) =>
    Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final raw in const [_qrA, _qrB, _singleToken])
          TextButton(
            onPressed: () => onDetect(_capture([raw])),
            child: Text('scan:${raw.substring(raw.length - 4)}'),
          ),
        TextButton(
          onPressed: () => onDetect(_capture(const [_qrA, _qrB])),
          child: const Text('scan:iki'),
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
  Future<void> Function()? onStop,
  Future<void> Function()? onStart,
  DateTime Function()? now,
  ValueListenable<MobileScannerState>? scannerState,
}) async {
  final vault = VaultCubit(repo ?? _FakeRepo());
  await vault.load();
  addTearDown(vault.close);
  if (existing.isNotEmpty) await vault.addAll(existing);

  final page = ScanPage(
    debugMigration: migration,
    debugScannerBuilder: _fakeScanner,
    debugCamera: (
      stop: onStop ?? () async {},
      start: onStart ?? () async {},
    ),
    debugNow: now,
    debugScannerState: scannerState,
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
      var starts = 0;
      await _pumpScan(tester,
          migration: migration, onStart: () async => starts++);

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
      expect(starts, 0);
      expect(find.text('1/3 kod tarandı'), findsOneWidget);
    });

    testWidgets('"Baştan başla" → reset + kamera yeniden başlatılır',
        (tester) async {
      final migration = build();
      var stops = 0;
      var starts = 0;
      await _pumpScan(
        tester,
        migration: migration,
        onStop: () async => stops++,
        onStart: () async => starts++,
      );

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
      expect(stops, 1);
      expect(starts, 1);
      expect(find.textContaining('kod tarandı'), findsNothing);
    });

    testWidgets('stop() hata verse de start() ATLANMAZ', (tester) async {
      final migration = build();
      var stops = 0;
      var starts = 0;
      await _pumpScan(
        tester,
        migration: migration,
        onStop: () async {
          stops++;
          throw StateError('kamera durdurulamadı');
        },
        onStart: () async => starts++,
      );

      await tester.tap(_scan('AAAA'));
      await tester.pumpAndSettle();
      await tester.tap(_scan('BBBB'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Baştan başla'));
      await tester.pumpAndSettle();

      expect(stops, 1);
      // Yoksa "Baştan başla" sonrası ekran ölü kalırdı: kamera durmuş
      // sayılıp bir daha başlatılmaz.
      expect(starts, 1);
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

  group('tek karede birden çok barkod', () {
    testWidgets('migration modunda karedeki TÜM kodlar işlenir',
        (tester) async {
      final migration = _FakeMigration(script: const {
        _qrA: MigrationBatchAdded(1, 2),
        _qrB: MigrationScanComplete(2, 2),
      });
      await _pumpScan(tester, migration: migration);

      await tester.tap(_scan('AAAA'));
      await tester.pumpAndSettle();
      expect(find.text('1/2 kod tarandı'), findsOneWidget);

      // Android'de `lastScanned` karenin tamamını yazar → ikinci QR bir daha
      // yayınlanmaz. Yalnız ilkini alsaydık o kod SONSUZA DEK kaybolurdu.
      await tester.tap(find.text('scan:iki'));
      await tester.pumpAndSettle();

      expect(migration.seen, [_qrA, _qrA, _qrB]);
      expect(find.text('2/2 kod tarandı'), findsOneWidget);
    });

    testWidgets('tek-token modunda karenin yalnız ilk barkodu işlenir',
        (tester) async {
      final migration =
          _FakeMigration(script: const {_qrA: MigrationBatchAdded(1, 2)});
      await _pumpScan(tester, migration: migration);

      await tester.tap(find.text('scan:iki'));
      await tester.pumpAndSettle();

      expect(migration.seen, [_qrA]);
      expect(find.text('1/2 kod tarandı'), findsOneWidget);
    });
  });

  testWidgets('önizleme açılırken gelen ham QR YOK SAYILIR', (tester) async {
    final stopGate = Completer<void>();
    final migration = _FakeMigration(
      script: const {
        _qrA: MigrationScanComplete(1, 1),
        _qrB: MigrationBatchAdded(2, 2),
      },
      previewResult:
          ImportPreview(source: ImportSource.googleAuth, toAdd: [_acc('a')]),
    );
    await _pumpScan(tester, migration: migration, onStop: () => stopGate.future);

    await tester.tap(_scan('AAAA'));
    await tester.pumpAndSettle();
    expect(migration.seen, [_qrA]);

    // "Devam" → `_showPreview` kamerayı durdurmayı BEKLİYOR; iOS'ta bu
    // pencerede aynı/başka bir kare gelmeye devam eder.
    await tester.tap(find.widgetWithText(FilledButton, 'Devam'));
    await tester.pump();
    await tester.tap(_scan('BBBB'));
    await tester.pump();

    expect(migration.seen, [_qrA],
        reason: 'önizleme istendikten sonra gelen kare koleksiyona girmemeli');

    stopGate.complete();
    await tester.pumpAndSettle();
    expect(find.text('1 token içe aktarılacak'), findsOneWidget);
  });

  testWidgets('aynı hata üst üste → tek SnackBar, pencere dolunca yeniden',
      (tester) async {
    var now = DateTime(2026, 1, 1);
    final migration = _FakeMigration(script: const {
      _qrA: MigrationBatchAdded(1, 2),
      _qrB: MigrationDuplicateScan(),
    });
    await _pumpScan(tester, migration: migration, now: () => now);

    double snackBarValue() =>
        tester.widget<SnackBar>(find.byType(SnackBar)).animation!.value;

    await tester.tap(_scan('AAAA'));
    await tester.pumpAndSettle();

    await tester.tap(_scan('BBBB'));
    await tester.pumpAndSettle();
    expect(find.text('Bu kod zaten okundu'), findsOneWidget);
    expect(snackBarValue(), 1.0);

    // Kadrajda duran QR: iOS'ta `noDuplicates` payload karşılaştırmadığı için
    // aynı olay her karede yeniden gelir. Throttle olmadan her tekrar
    // `clearSnackBars()` çağırır → gizlenme animasyonu başlar.
    for (var i = 0; i < 4; i++) {
      await tester.tap(_scan('BBBB'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.byType(SnackBar), findsOneWidget);
    // Yeniden gösterilseydi `clearSnackBars()` gizlenme animasyonunu
    // başlatırdı ve değer 1.0'ın altına düşerdi.
    expect(snackBarValue(), 1.0,
        reason: 'throttle: SnackBar hiç yeniden gösterilmedi');
    expect(migration.seen.length, 6, reason: 'kareler yine de işlendi');

    // Pencere dolunca aynı mesaj yeniden gösterilir.
    now = now.add(ScanPage.errorRepeatWindow);
    await tester.tap(_scan('BBBB'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(snackBarValue(), lessThan(1.0),
        reason: 'pencere doldu → eski SnackBar gizlenip yenisi kuyruğa girdi');

    await tester.pumpAndSettle();
    expect(find.text('Bu kod zaten okundu'), findsOneWidget);
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

  group('C2 — kamera aksiyonları', () {
    /// `MobileScannerState` sadece durum taşıyan bir değer nesnesi → gerçek
    /// kamera olmadan da AppBar aksiyonlarının gördüğü akış kurulabilir.
    ValueNotifier<MobileScannerState> notifier({
      required bool initialized,
      TorchState torch = TorchState.off,
    }) {
      const base = MobileScannerState.uninitialized();
      final n = ValueNotifier(
        base.copyWith(isInitialized: initialized, torchState: torch),
      );
      addTearDown(n.dispose);
      return n;
    }

    Finder torchBtn() => find.widgetWithIcon(IconButton, Icons.flash_on);
    Finder swapBtn() => find.widgetWithIcon(IconButton, Icons.cameraswitch);

    testWidgets('kamera hazır DEĞİLKEN aksiyonlar pasif', (tester) async {
      // `toggleTorch`/`switchCamera` ilk iş olarak `_throwIfNotInitialized()`
      // çağırır → aktif bir düğme yakalanmamış exception demekti.
      await _pumpScan(
        tester,
        migration: _FakeMigration(),
        scannerState: notifier(initialized: false),
      );

      expect(tester.widget<IconButton>(swapBtn()).onPressed, isNull);
      expect(tester.widget<IconButton>(torchBtn()).onPressed, isNull);
    });

    testWidgets('kamera hazır olunca aksiyonlar aktifleşir', (tester) async {
      final state = notifier(initialized: false);
      await _pumpScan(
        tester,
        migration: _FakeMigration(),
        scannerState: state,
      );
      expect(tester.widget<IconButton>(swapBtn()).onPressed, isNull);

      state.value = state.value.copyWith(isInitialized: true);
      await tester.pump();

      expect(tester.widget<IconButton>(swapBtn()).onPressed, isNotNull);
      expect(tester.widget<IconButton>(torchBtn()).onPressed, isNotNull);
    });

    testWidgets('flaşı olmayan cihazda flaş düğmesi GİZLENİR', (tester) async {
      await _pumpScan(
        tester,
        migration: _FakeMigration(),
        scannerState:
            notifier(initialized: true, torch: TorchState.unavailable),
      );

      expect(torchBtn(), findsNothing);
      expect(swapBtn(), findsOneWidget, reason: 'kamera değiştirme kalır');
    });

    testWidgets('önizleme adımında aksiyonlar hiç gösterilmez', (tester) async {
      final migration = _FakeMigration(
        script: const {_qrA: MigrationScanComplete(1, 1)},
        previewResult: ImportPreview(
            source: ImportSource.googleAuth, toAdd: [_acc('a')]),
      );
      await _pumpScan(
        tester,
        migration: migration,
        scannerState: notifier(initialized: true),
      );

      await tester.tap(_scan('AAAA'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devam'));
      await tester.pumpAndSettle();

      expect(find.text('1 token içe aktarılacak'), findsOneWidget);
      expect(torchBtn(), findsNothing);
      expect(swapBtn(), findsNothing);
    });
  });

  group('C5 — migration sırasındaki uyarılar', () {
    testWidgets('araya giren tek-token QR\'ı kendi mesajını alır',
        (tester) async {
      final migration =
          _FakeMigration(script: const {_qrA: MigrationBatchAdded(1, 3)});
      await _pumpScan(tester, migration: migration);

      await tester.tap(_scan('AAAA'));
      await tester.pumpAndSettle();
      await tester.tap(_scan('3PXP')); // geçerli tek-token otpauth:// QR'ı
      await tester.pump();

      expect(
        find.text('Aktarım sürüyor — önce kalan kodları okut ya da Baştan '
            'başla.'),
        findsOneWidget,
      );
      expect(
        find.text(
            'Bu QR bir Google Authenticator aktarım kodu değil ya da bozuk.'),
        findsNothing,
        reason: 'geçerli bir kod "bozuk" diye etiketlenmemeli',
      );
      expect(find.text('1/3 kod tarandı'), findsOneWidget,
          reason: 'toplananlar korunur');
    });

    testWidgets('diyalog AÇIKKEN gelen aynı QR sessiz kalmaz', (tester) async {
      final migration = _FakeMigration(script: const {
        _qrA: MigrationBatchAdded(1, 3),
        _qrB: MigrationDifferentBatch(),
      });
      await _pumpScan(tester, migration: migration);

      await tester.tap(_scan('AAAA'));
      await tester.pumpAndSettle();
      await tester.tap(_scan('BBBB'));
      await tester.pumpAndSettle();
      expect(
          find.text('Bu QR farklı bir dışa aktarmaya ait. Baştan başlansın mı?'),
          findsOneWidget);

      // iOS'ta kadrajda duran QR her karede yeniden gelir → ikinci kare.
      // Yer tutucu "kamera" diyalogun ALTINDA kaldığı için tap modal bariyere
      // çarpar → kare gerçek kameradaki gibi doğrudan yayınlanır.
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'scan:BBBB'))
          .onPressed!();
      await tester.pump();
      await tester.pump();

      expect(find.text('Bu kod için soru zaten açık.'), findsOneWidget);
      expect(
          find.text('Bu QR farklı bir dışa aktarmaya ait. Baştan başlansın mı?'),
          findsOneWidget,
          reason: 'ikinci diyalog YIĞILMAZ');

      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
    });
  });
}
