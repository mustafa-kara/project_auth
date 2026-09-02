/// Faz 5 Patch 3 (plan §5 D5) — `ScanPage`'in "Görüntüden oku" yolu.
///
/// Kamerası olmayan / izni reddetmiş / QR'ı ekran görüntüsü olarak saklamış
/// kullanıcının yolu bu. Host VM'de ne seçici ne de platform çözücü çalışır →
/// ikisi de tohumla değiştirilir (`debugDocuments`, `debugQrDecoder`); çözülen
/// ham metin kamera karesiyle BİREBİR aynı yola (`_handleRaw`) girer, o yüzden
/// hem tek-token hem aktarım modu buradan da sürülebilir.
///
/// Sınananlar: kilit muafiyetinin her yolda açılıp kapanması, seçicinin
/// bıraktığı DÜZ nüshanın her yolda silinmesi, kamera durdur/başlat dengesi ve
/// hata metinlerinin sabitliği.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/import_export/domain/file_port.dart';
import 'package:project_auth/features/import_export/domain/import_exceptions.dart';
import 'package:project_auth/features/import_export/domain/import_service.dart';
import 'package:project_auth/features/import_export/domain/qr_image_decoder.dart';
import 'package:project_auth/features/scan/presentation/migration_scan_controller.dart';
import 'package:project_auth/features/scan/presentation/scan_page.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';

const _singleToken =
    'otpauth://totp/Example:me@example.com?secret=JBSWY3DPEHPK3PXP';
const _qrA = 'otpauth-migration://offline?data=AAAA';
const _qrB = 'otpauth-migration://offline?data=BBBB';

class _FakeRepo implements VaultRepository {
  List<OtpAccount> stored = [];

  @override
  Future<VaultLoadResult> load() async =>
      VaultLoadResult(accounts: List.of(stored));
  @override
  Future<void> save(List<OtpAccount> accounts) async => stored = List.of(accounts);
  @override
  Future<void> purgeCorrupted() async {}
}

/// Kilit muafiyetini SAYAN sahte cubit — `beginSystemFileFlow` /
/// `endSystemFileFlow` dengesinin kanıtı.
class _CountingLockCubit extends Cubit<VaultLockState>
    implements VaultLockCubit {
  _CountingLockCubit() : super(const VaultLockState.unlocked());

  int begins = 0;
  int ends = 0;

  @override
  void beginSystemFileFlow({Duration budget = const Duration(minutes: 2)}) =>
      begins++;

  @override
  void endSystemFileFlow() => ends++;

  @override
  bool get systemFileFlowActive => begins > ends;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Görüntü seçici tohumu. [imagePath] doldurulmuşsa o yol seçilmiş sayılır;
/// `null` iptal demektir.
class _FakeDocuments implements DocumentPort {
  /// Alanlar testte doğrudan set edilir (aynı örnek `pumpScan`'e verilmiş
  /// olabilir) → kurucu parametresi yok.
  String? imagePath;
  Object? pickError;

  int picks = 0;
  int clears = 0;
  int? lastMaxBytes;

  @override
  Future<PickedImage?> pickImage({required int maxBytes}) async {
    picks++;
    lastMaxBytes = maxBytes;
    if (pickError != null) throw pickError!;
    final path = imagePath;
    if (path == null) return null;
    return PickedImage(
        path: path, name: 'qr.png', sizeBytes: File(path).lengthSync());
  }

  /// Sıra kanıtı: genel temizlik çağrıldığında seçicinin bıraktığı nüsha ARTIK
  /// olmamalı. `shredCachedCopy` sıfırla-sonra-sil yapar; ters sırada
  /// `clearPickerCache` dosyayı ÜZERİNE YAZMADAN unlink ederdi ve düz baytlar
  /// diskte kalırdı (Patch 3 güvenlik hijyeni).
  @override
  Future<void> clearPickerCache() async {
    clears++;
    final path = imagePath;
    if (path != null && File(path).existsSync()) {
      fail('shred must run before clearPickerCache');
    }
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// `MigrationScanController` somut sınıf → `implements` ile sahtelenir.
class _FakeMigration implements MigrationScanController {
  _FakeMigration({this.script = const {}});

  final Map<String, MigrationScanEvent> script;
  final List<String> seen = [];
  int resets = 0;

  @override
  MigrationScanEvent handleRaw(String raw) {
    seen.add(raw);
    return script[raw] ?? const MigrationMalformedQr();
  }

  @override
  ImportPreview preview({required List<OtpAccount> existing}) =>
      throw UnimplementedError();

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

/// Kamera yerine geçen yer tutucu — bu dosyada hiç karesi okunmaz.
Widget _fakeScanner(
        BuildContext context, void Function(BarcodeCapture capture) onDetect) =>
    const SizedBox.shrink();

final Finder _imageAction =
    find.widgetWithIcon(IconButton, Icons.image_outlined);

void main() {
  late Directory cacheDir;
  late _CountingLockCubit lock;
  late _FakeDocuments documents;
  late int stops;
  late int starts;

  setUp(() {
    cacheDir = Directory.systemTemp.createTempSync('pa_picker_');
    lock = _CountingLockCubit();
    documents = _FakeDocuments();
    stops = 0;
    starts = 0;
  });

  tearDown(() {
    lock.close();
    if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
  });

  /// Seçicinin bıraktığı düz nüshayı taklit eden gerçek bir dosya.
  File seedCachedImage([String contents = 'PNG-benzeri baytlar']) {
    final file = File('${cacheDir.path}${Platform.pathSeparator}qr.png')
      ..writeAsStringSync(contents);
    documents.imagePath = file.path;
    return file;
  }

  Future<VaultCubit> pumpScan(
    WidgetTester tester, {
    required QrImageDecoder decoder,
    _FakeRepo? repo,
    _FakeMigration? migration,
  }) async {
    final vault = VaultCubit(repo ?? _FakeRepo());
    await vault.load();
    addTearDown(vault.close);

    final page = ScanPage(
      debugMigration: migration,
      debugScannerBuilder: _fakeScanner,
      debugCamera: (
        stop: () async => stops++,
        start: () async => starts++,
      ),
      debugQrDecoder: decoder,
      debugDocuments: documents,
    );

    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<VaultCubit>.value(value: vault),
        BlocProvider<VaultLockCubit>.value(value: lock),
      ],
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
    ));
    await tester.tap(find.text('tarayıcıyı aç'));
    await tester.pumpAndSettle();
    return vault;
  }

  QrImageDecoder decoderOf(List<String> raws) => (_) async => raws;
  QrImageDecoder throwingDecoder(Object error) => (_) async => throw error;

  testWidgets('aksiyon AppBar\'da ve kamera durumundan bağımsız',
      (tester) async {
    await pumpScan(tester, decoder: decoderOf(const []));
    expect(_imageAction, findsOneWidget);
    expect(
      tester.widget<IconButton>(_imageAction).onPressed,
      isNotNull,
      reason: 'analyzeImage kamera/izin istemez → buton hep etkin',
    );
  });

  testWidgets('iptal: muafiyet açılıp kapanır, kamera geri gelir',
      (tester) async {
    documents.imagePath = null; // iptal
    await pumpScan(tester, decoder: decoderOf(const []));

    await tester.tap(_imageAction);
    await tester.pumpAndSettle();

    expect(documents.picks, 1);
    expect(lock.begins, 1);
    expect(lock.ends, 1, reason: 'iptalde de muafiyet kapanmalı');
    expect(documents.clears, 1, reason: 'temizlik her yolda');
    expect(stops, 1);
    expect(starts, 1, reason: 'iptal sonrası taramaya devam');
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('görüntüde QR yok → sabit mesaj, nüsha silinir', (tester) async {
    final cached = seedCachedImage();
    await pumpScan(tester, decoder: decoderOf(const []));

    await tester.tap(_imageAction);
    await tester.pumpAndSettle();

    expect(find.text('Bu görüntüde QR kod bulunamadı.'), findsOneWidget);
    expect(cached.existsSync(), isFalse,
        reason: 'nüsha canlı secret\'ın düz resmi — diskte kalmamalı');
    expect(documents.clears, 1);
    expect(lock.ends, 1);
  });

  testWidgets('tek otpauth QR → token eklenir ve ekran kapanır',
      (tester) async {
    seedCachedImage();
    final repo = _FakeRepo();
    final vault = await pumpScan(tester,
        decoder: decoderOf(const [_singleToken]), repo: repo);

    await tester.tap(_imageAction);
    await tester.pumpAndSettle();

    expect(vault.state.accounts.length, 1);
    expect(repo.stored.length, 1);
    expect(_imageAction, findsNothing, reason: 'ekran kapanmalı');
    expect(documents.clears, 1);
    expect(lock.ends, 1);
  });

  testWidgets('tek görüntüdeki iki aktarım QR\'ı sırayla işlenir',
      (tester) async {
    seedCachedImage();
    final migration = _FakeMigration(script: const {
      _qrA: MigrationBatchAdded(1, 2),
      _qrB: MigrationScanComplete(2, 2),
    });
    await pumpScan(tester,
        decoder: decoderOf(const [_qrA, _qrB]), migration: migration);

    await tester.tap(_imageAction);
    await tester.pumpAndSettle();

    expect(migration.seen, const [_qrA, _qrB]);
    expect(find.text('2/2 kod tarandı'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Devam'), findsOneWidget);
    expect(starts, 1, reason: 'önizlemeye geçilmedi → kamera geri gelir');
  });

  testWidgets('desteklenmeyen platform → cihaza özgü mesaj', (tester) async {
    seedCachedImage();
    await pumpScan(tester,
        decoder: throwingDecoder(const QrImageUnsupportedException()));

    await tester.tap(_imageAction);
    await tester.pumpAndSettle();

    expect(
        find.text('Bu cihazda görüntüden okuma desteklenmiyor.'), findsOneWidget);
    expect(documents.clears, 1, reason: 'temizlik her yolda');
    expect(lock.ends, 1);
  });

  testWidgets('çözülemeyen görüntü → "okunamadı", neden açıklanmaz',
      (tester) async {
    final cached = seedCachedImage();
    await pumpScan(tester,
        decoder: throwingDecoder(const QrImageUnreadableException()));

    await tester.tap(_imageAction);
    await tester.pumpAndSettle();

    expect(find.text('Görüntü okunamadı.'), findsOneWidget);
    expect(cached.existsSync(), isFalse);
    expect(documents.clears, 1);
  });

  testWidgets('boyut tavanı seçicide uygulanır → çözücü HİÇ çağrılmaz',
      (tester) async {
    documents.pickError = const ImportFileTooLargeException(1 << 30, 1 << 24);
    var decoded = 0;
    await pumpScan(tester, decoder: (_) async {
      decoded++;
      return const [];
    });

    await tester.tap(_imageAction);
    await tester.pumpAndSettle();

    expect(find.text('Görüntü çok büyük (en fazla 16 MB).'), findsOneWidget);
    expect(decoded, 0);
    expect(documents.lastMaxBytes, QrImageLimits.maxBytes);
    expect(documents.clears, 1, reason: 'reddedilen nüsha da temizlenmeli');
    expect(lock.ends, 1);
    expect(starts, 1);
  });

  testWidgets('seçici patlarsa muafiyet ve temizlik yine kapanır',
      (tester) async {
    documents.pickError = StateError('picker crashed');
    await pumpScan(tester, decoder: decoderOf(const []));

    await tester.tap(_imageAction);
    await tester.pumpAndSettle();

    expect(find.text('Görüntü okunamadı.'), findsOneWidget);
    expect(lock.begins, 1);
    expect(lock.ends, 1);
    expect(documents.clears, 1);
  });

  testWidgets('seçici açıkken sayfa sökülürse muafiyet kapatılır',
      (tester) async {
    final gate = Completer<PickedImage?>();
    documents = _StuckDocuments(gate.future);
    await pumpScan(tester, decoder: decoderOf(const []));

    await tester.tap(_imageAction);
    await tester.pump(); // seçici "açık"

    expect(lock.begins, 1);
    expect(lock.ends, 0);

    // Kullanıcı geri gitti / rota değişti.
    final state = tester.state<NavigatorState>(find.byType(Navigator).first);
    state.pop();
    await tester.pumpAndSettle();

    expect(lock.ends, 1, reason: 'dispose muafiyeti kapatmalı');
    gate.complete(null);
    await tester.pumpAndSettle();
  });
}

/// Sonucu testin kontrolündeki bir future'a bağlayan seçici: "sistem seçicisi
/// hâlâ açık" durumunu taklit eder.
class _StuckDocuments extends _FakeDocuments {
  _StuckDocuments(this._gate);

  final Future<PickedImage?> _gate;

  @override
  Future<PickedImage?> pickImage({required int maxBytes}) {
    picks++;
    lastMaxBytes = maxBytes;
    return _gate;
  }
}
