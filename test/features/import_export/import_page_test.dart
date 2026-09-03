/// Faz 5 Patch 1 — ImportPage widget testleri (plan §5.3).
///
/// Servis sözleşmeleri `implements` ile sahtelenir (Dart'ta concrete sınıf da
/// implements edilebilir): sayfa gerçek `ImportService`/`BackupService`
/// gövdelerine değil SÖZLEŞMEYE karşı doğrulanır, böylece libsodium, file_picker
/// ve DI olmadan koşar ve parser değişiklikleri bu dosyayı kırmaz.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/router/app_router.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/import_export/domain/backup_service.dart';
import 'package:project_auth/features/import_export/domain/file_port.dart';
import 'package:project_auth/features/import_export/domain/import_exceptions.dart';
import 'package:project_auth/features/import_export/domain/import_models.dart';
import 'package:project_auth/features/import_export/domain/import_service.dart';
import 'package:project_auth/features/import_export/presentation/pages/import_page.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';

// --- Fakes ---

OtpAccount _acc(String name) => OtpAccount(
  secret: 'JBSWY3DPEHPK3PXP',
  type: OtpType.totp,
  accountName: name,
);

class _FakeRepo implements VaultRepository {
  List<OtpAccount> stored = [];
  @override
  Future<VaultLoadResult> load() async =>
      VaultLoadResult(accounts: List.of(stored));
  @override
  Future<void> save(List<OtpAccount> accounts) async =>
      stored = List.of(accounts);
  @override
  Future<void> purgeCorrupted() async {}
}

/// Kilit muafiyetinin begin/end çiftini sayar (plan §3.2).
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

  /// Kayıtlı plaintext temizleyicileri (güvenlik denetimi P2-1). Sayfa
  /// `didChangeDependencies`'te kaydolur, `dispose`'ta kaydı geri alır;
  /// `noSuchMethod` null döndüğü için burada GERÇEKLENMESİ ZORUNLU (dönüş tipi
  /// `VoidCallback`).
  final List<void Function()> plaintextHolders = [];

  @override
  VoidCallback registerPlaintextHolder(void Function() wipe) {
    plaintextHolders.add(wipe);
    return () => plaintextHolders.remove(wipe);
  }

  /// Testte "masterKey dispose edildi" anını taklit eder.
  void firePlaintextWipe() {
    for (final w in List<void Function()>.of(plaintextHolders)) {
      w();
    }
  }

  @override
  noSuchMethod(Invocation i) {}
}

class _FakeDocuments implements DocumentPort {
  _FakeDocuments({this.document, this.pickError, this.gate});

  /// null → kullanıcı iptal etti.
  final PickedDocument? document;
  final Object? pickError;

  /// Doluysa `pickJson` bu completer tamamlanana kadar ASILI kalır — sistem
  /// seçicisi hâlâ ekrandayken sayfanın sökülmesini simüle eder.
  final Completer<PickedDocument?>? gate;

  int pickCount = 0;

  @override
  Future<PickedDocument?> pickJson({required int maxBytes}) async {
    pickCount++;
    final open = gate;
    if (open != null) return open.future;
    if (pickError != null) throw pickError!;
    return document;
  }

  @override
  Future<bool> saveJson({
    required String fileName,
    required Uint8List bytes,
  }) async => true;

  // Faz 5 Patch 3 — görüntüden okuma ScanPage'in yolu; burada kullanılmaz.
  @override
  Future<PickedImage?> pickImage({required int maxBytes}) async => null;

  @override
  Future<void> clearPickerCache() async {}
}

class _FakeImportService implements ImportService {
  _FakeImportService({
    this.detected = ImportSource.aegis,
    this.result,
    this.detectError,
    this.previewError,
  });

  final ImportSource detected;
  final ImportPreview? result;
  final Object? detectError;
  final Object? previewError;

  String? lastPassword;
  int previewCount = 0;

  @override
  ImportSource detect(String raw) {
    if (detectError != null) throw detectError!;
    return detected;
  }

  @override
  Future<ImportPreview> preview({
    required String raw,
    required List<OtpAccount> existing,
    String? backupPassword,
  }) async {
    previewCount++;
    lastPassword = backupPassword;
    if (previewError != null) throw previewError!;
    return result!;
  }

  @override
  ImportPreview previewParsed(
    ParsedImport parsed, {
    required List<OtpAccount> existing,
  }) => throw UnimplementedError();

  @override
  BackupService get backup => throw UnimplementedError();
  @override
  List<ImportParser> get parsers => const [];
}

PickedDocument _doc([String body = '{"db":{},"header":{}}']) =>
    PickedDocument('yedek.json', Uint8List.fromList(utf8.encode(body)));

Future<VaultCubit> _pumpPage(
  WidgetTester tester, {
  required _FakeImportService service,
  required _FakeDocuments documents,
  required _FakeLock lock,
  _FakeRepo? repo,
}) async {
  final vault = VaultCubit(repo ?? _FakeRepo());
  await vault.load();
  addTearDown(vault.close);
  await tester.pumpWidget(
    MultiBlocProvider(
      providers: [
        BlocProvider<VaultLockCubit>.value(value: lock),
        BlocProvider<VaultCubit>.value(value: vault),
      ],
      child: MaterialApp(
        home: ImportPage(service: service, documents: documents),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return vault;
}

void main() {
  late _FakeLock lock;

  setUp(() => lock = _FakeLock());
  tearDown(() => lock.close());

  testWidgets('açılışta dosya seçme boş durumu gösterir', (tester) async {
    await _pumpPage(
      tester,
      service: _FakeImportService(
        result: const ImportPreview(source: ImportSource.aegis, toAdd: []),
      ),
      documents: _FakeDocuments(),
      lock: lock,
    );
    expect(find.text('Yedek dosyası seç'), findsOneWidget);
    expect(find.text('Dosya seç'), findsOneWidget);
  });

  testWidgets('dosya seçimi kilit muafiyetini açar VE kapatır (plan §3.2)', (
    tester,
  ) async {
    final preview = ImportPreview(
      source: ImportSource.aegis,
      toAdd: [_acc('a')],
    );
    final docs = _FakeDocuments(document: _doc());
    await _pumpPage(
      tester,
      service: _FakeImportService(result: preview),
      documents: docs,
      lock: lock,
    );

    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();

    expect(docs.pickCount, 1);
    expect(lock.begins, 1);
    expect(lock.ends, 1, reason: 'finally her yolda end çağırmalı');
  });

  testWidgets('picker hata atsa bile kilit muafiyeti kapatılır', (
    tester,
  ) async {
    final docs = _FakeDocuments(
      pickError: const ImportFileTooLargeException(9000000, 8388608),
    );
    await _pumpPage(
      tester,
      service: _FakeImportService(
        result: const ImportPreview(source: ImportSource.aegis, toAdd: []),
      ),
      documents: docs,
      lock: lock,
    );

    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();

    expect(lock.begins, 1);
    expect(lock.ends, 1);
    expect(find.text('Dosya çok büyük (max 8 MB).'), findsOneWidget);
  });

  testWidgets('önizleme: kaynak rozeti + sayılar render edilir', (
    tester,
  ) async {
    final preview = ImportPreview(
      source: ImportSource.twofas,
      toAdd: [_acc('a'), _acc('b')],
      skipped: const [
        SkippedEntry(reason: SkipReason.alreadyInVault, label: 'GitHub (me)'),
        SkippedEntry(
          reason: SkipReason.unsupportedType,
          label: 'Yandex (x)',
          detail: 'yandex',
        ),
      ],
    );
    await _pumpPage(
      tester,
      service: _FakeImportService(
        detected: ImportSource.twofas,
        result: preview,
      ),
      documents: _FakeDocuments(document: _doc()),
      lock: lock,
    );

    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();

    expect(find.text('2FAS'), findsOneWidget);
    expect(find.text('2 token içe aktarılacak'), findsOneWidget);
    expect(find.text('1 zaten var'), findsOneWidget);
    expect(find.text('1 desteklenmiyor'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'İçe aktar'), findsOneWidget);
  });

  testWidgets('atlananlar ExpansionTile\'da etiket + neden ile listelenir', (
    tester,
  ) async {
    final preview = ImportPreview(
      source: ImportSource.aegis,
      toAdd: [_acc('a')],
      skipped: const [
        SkippedEntry(
          reason: SkipReason.unsupportedType,
          label: 'Yandex (x)',
          detail: 'yandex',
        ),
      ],
    );
    await _pumpPage(
      tester,
      service: _FakeImportService(result: preview),
      documents: _FakeDocuments(document: _doc()),
      lock: lock,
    );

    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();

    expect(find.text('Atlananlar (1)'), findsOneWidget);
    await tester.tap(find.text('Atlananlar (1)'));
    await tester.pumpAndSettle();

    expect(find.text('Yandex (x)'), findsOneWidget);
    expect(find.text('Desteklenmeyen token türü — yandex'), findsOneWidget);
  });

  testWidgets('"İçe aktar" → VaultCubit.addAll çağrılır + SnackBar', (
    tester,
  ) async {
    final toAdd = [_acc('a'), _acc('b')];
    final repo = _FakeRepo();
    final vault = await _pumpPage(
      tester,
      service: _FakeImportService(
        result: ImportPreview(source: ImportSource.aegis, toAdd: toAdd),
      ),
      documents: _FakeDocuments(document: _doc()),
      lock: lock,
      repo: repo,
    );

    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'İçe aktar'));
    await tester.pumpAndSettle();

    expect(vault.state.accounts.map((e) => e.id), toAdd.map((e) => e.id));
    expect(repo.stored.length, 2, reason: 'addAll persist etmeli');
    expect(find.text('2 token eklendi'), findsOneWidget);
  });

  testWidgets('boş önizlemede "İçe aktar" pasif', (tester) async {
    await _pumpPage(
      tester,
      service: _FakeImportService(
        result: const ImportPreview(source: ImportSource.aegis, toAdd: []),
      ),
      documents: _FakeDocuments(document: _doc()),
      lock: lock,
    );

    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'İçe aktar'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('kendi şifreli yedeğimiz → parola adımı, sonra preview\'a parola '
      'geçirilir', (tester) async {
    final service = _FakeImportService(
      detected: ImportSource.projectauthBackup,
      result: ImportPreview(
        source: ImportSource.projectauthBackup,
        toAdd: [_acc('a')],
      ),
    );
    await _pumpPage(
      tester,
      service: service,
      documents: _FakeDocuments(
        document: _doc('{"format":"projectauth-backup"}'),
      ),
      lock: lock,
    );

    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();

    expect(find.text('Bu dosya şifreli bir yedek'), findsOneWidget);
    expect(service.previewCount, 0, reason: 'parola alınmadan preview yok');

    await tester.enterText(find.byType(TextFormField), 'Yedek-Parolam-123');
    await tester.tap(find.text('Devam'));
    await tester.pumpAndSettle();

    expect(service.lastPassword, 'Yedek-Parolam-123');
    expect(find.text('1 token içe aktarılacak'), findsOneWidget);
  });

  testWidgets('yanlış yedek parolası → Türkçe hata, adım değişmez', (
    tester,
  ) async {
    final service = _FakeImportService(
      detected: ImportSource.projectauthBackup,
      previewError: const WrongBackupPasswordException(),
    );
    await _pumpPage(
      tester,
      service: service,
      documents: _FakeDocuments(
        document: _doc('{"format":"projectauth-backup"}'),
      ),
      lock: lock,
    );

    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'yanlis-parola-123');
    await tester.tap(find.text('Devam'));
    await tester.pumpAndSettle();

    expect(find.text('Parola yanlış ya da dosya bozulmuş.'), findsOneWidget);
    expect(find.text('Bu dosya şifreli bir yedek'), findsOneWidget);
  });

  testWidgets('desteklenmeyen biçim → yönlendirici Türkçe hata', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      service: _FakeImportService(
        detectError: const UnsupportedImportFormatException(),
      ),
      documents: _FakeDocuments(document: _doc('{"baska":1}')),
      lock: lock,
    );

    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Bu dosya biçimi desteklenmiyor'),
      findsOneWidget,
    );
  });

  testWidgets('şifreli Aegis kaynağı → kaynağa özel yönlendirme', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      service: _FakeImportService(
        detectError: const EncryptedSourceException(ImportSource.aegis),
      ),
      documents: _FakeDocuments(document: _doc()),
      lock: lock,
    );

    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Aegis yedeği parolayla şifrelenmiş'),
      findsOneWidget,
    );
  });

  testWidgets('kullanıcı iptal ederse adım değişmez, hata gösterilmez', (
    tester,
  ) async {
    final docs = _FakeDocuments(); // document null = iptal
    await _pumpPage(
      tester,
      service: _FakeImportService(
        result: const ImportPreview(source: ImportSource.aegis, toAdd: []),
      ),
      documents: docs,
      lock: lock,
    );

    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();

    expect(find.text('Yedek dosyası seç'), findsOneWidget);
    expect(lock.ends, 1);
  });

  testWidgets('picker AÇIKKEN sayfa sökülürse muafiyet dispose\'ta kapanır', (
    tester,
  ) async {
    final gate = Completer<PickedDocument?>();
    final docs = _FakeDocuments(gate: gate);
    await _pumpPage(
      tester,
      service: _FakeImportService(
        result: const ImportPreview(source: ImportSource.aegis, toAdd: []),
      ),
      documents: docs,
      lock: lock,
    );

    await tester.tap(find.text('Dosya seç'));
    await tester.pump(); // seçici açıldı, sonuç HENÜZ yok
    expect(lock.begins, 1);
    expect(lock.ends, 0);
    expect(lock.systemFileFlowActive, isTrue);

    // Router redirect / geri hareketi / kilit → sayfa unmount olur ve
    // `_pickFile`'ın `finally`'si HENÜZ çalışmamıştır.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();

    expect(lock.ends, 1, reason: 'dispose muafiyeti kapatmalı');
    expect(lock.systemFileFlowActive, isFalse);

    gate.complete(null); // asılı future'ı temizle
    await tester.pumpAndSettle();
  });

  testWidgets('önizlemede secret EKRANA ÇIKMAZ', (tester) async {
    final preview = ImportPreview(
      source: ImportSource.aegis,
      toAdd: [_acc('a'), _acc('b')],
      skipped: const [
        SkippedEntry(reason: SkipReason.invalidSecret, label: 'Bozuk (x)'),
      ],
    );
    await _pumpPage(
      tester,
      service: _FakeImportService(result: preview),
      documents: _FakeDocuments(document: _doc()),
      lock: lock,
    );

    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();

    // `_acc` hepsini bu secret'la kurar; önizleme yalnız issuer/hesap gösterir.
    expect(find.textContaining('JBSWY3DP'), findsNothing);
    expect(find.textContaining('2 token içe aktarılacak'), findsOneWidget);
  });

  testWidgets(
    'Faz 5 Patch 2 — "Google Authenticator (QR)" → yönerge sheet\'i → /scan',
    (tester) async {
      final vault = VaultCubit(_FakeRepo());
      await vault.load();
      addTearDown(vault.close);

      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => ImportPage(
              service: _FakeImportService(
                result: const ImportPreview(
                  source: ImportSource.aegis,
                  toAdd: [],
                ),
              ),
              documents: _FakeDocuments(),
            ),
          ),
          // Gerçek ScanPage kamera ister → rota varlığını yer tutucuyla doğrula.
          GoRoute(
            path: Routes.scan,
            builder: (_, _) => const Scaffold(body: Text('SCAN-ROUTE')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<VaultLockCubit>.value(value: lock),
            BlocProvider<VaultCubit>.value(value: vault),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // Dosya seçme aksiyonu YERİNDE kalır (mevcut akış bozulmadı).
      expect(find.text('Dosya seç'), findsOneWidget);

      await tester.tap(find.text('Google Authenticator (QR)'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Hesapları dışa aktar'), findsOneWidget);

      await tester.tap(find.text('Kamerayı aç'));
      await tester.pumpAndSettle();

      expect(find.text('SCAN-ROUTE'), findsOneWidget);
    },
  );

  testWidgets('UTF-8 olmayan dosya → "okunamadı" hatası', (tester) async {
    final docs = _FakeDocuments(
      document: PickedDocument(
        'bozuk.json',
        Uint8List.fromList([0xC3, 0x28, 0xA0, 0xA1]),
      ),
    );
    await _pumpPage(
      tester,
      service: _FakeImportService(
        result: const ImportPreview(source: ImportSource.aegis, toAdd: []),
      ),
      documents: docs,
      lock: lock,
    );

    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();

    expect(
      find.text('Dosya okunamadı — geçerli bir JSON yedeği değil.'),
      findsOneWidget,
    );
  });

  testWidgets('A3: giriş tavanı aşılırsa Türkçe "çok fazla kayıt" hatası', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      service: _FakeImportService(
        previewError: const ImportTooManyEntriesException(5000, 1024),
      ),
      documents: _FakeDocuments(document: _doc()),
      lock: lock,
    );

    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();

    expect(
      find.text('Dosyada çok fazla kayıt var (en fazla 1024).'),
      findsOneWidget,
    );
  });

  testWidgets('C3: atlananlar 50 satırla sınırlı, kalanı "+k tane daha"', (
    tester,
  ) async {
    // 1024 tavanına yakın bir dosya: eager `ExpansionTile` hepsini tek karede
    // inşa ederdi. Sayılar (üstteki satırlar) TAM kalmalı, liste kısalmalı.
    final skipped = [
      for (var i = 0; i < 130; i++)
        SkippedEntry(reason: SkipReason.invalidFields, label: 'kayıt$i'),
    ];
    await _pumpPage(
      tester,
      service: _FakeImportService(
        result: ImportPreview(
          source: ImportSource.aegis,
          toAdd: [_acc('a')],
          skipped: skipped,
        ),
      ),
      documents: _FakeDocuments(document: _doc()),
      lock: lock,
    );
    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();

    expect(
      find.text('130 desteklenmiyor'),
      findsOneWidget,
      reason: 'sayılar kısaltmadan ETKİLENMEZ',
    );
    await tester.tap(find.text('Atlananlar (130)'));
    await tester.pumpAndSettle();

    expect(find.text('kayıt0'), findsOneWidget);
    expect(find.text('kayıt49'), findsOneWidget);
    expect(find.text('kayıt50'), findsNothing, reason: 'tavan 50 satır');
    expect(find.text('+80 tane daha'), findsOneWidget);
  });

  testWidgets('C3: 50 ve altında "daha" satırı YOK', (tester) async {
    await _pumpPage(
      tester,
      service: _FakeImportService(
        result: ImportPreview(
          source: ImportSource.aegis,
          toAdd: [_acc('a')],
          skipped: const [
            SkippedEntry(reason: SkipReason.invalidSecret, label: 'tek'),
          ],
        ),
      ),
      documents: _FakeDocuments(document: _doc()),
      lock: lock,
    );
    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlananlar (1)'));
    await tester.pumpAndSettle();

    expect(find.text('tek'), findsOneWidget);
    expect(find.textContaining('tane daha'), findsNothing);
  });

  testWidgets('C6: parola adımında "Başka dosya seç" → pick adımına döner', (
    tester,
  ) async {
    final docs = _FakeDocuments(document: _doc());
    await _pumpPage(
      tester,
      service: _FakeImportService(
        detected: ImportSource.projectauthBackup,
        result: ImportPreview(
          source: ImportSource.projectauthBackup,
          toAdd: [_acc('a')],
        ),
      ),
      documents: docs,
      lock: lock,
    );
    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();
    expect(find.text('Bu dosya şifreli bir yedek'), findsOneWidget);

    await tester.tap(find.text('Başka dosya seç'));
    await tester.pumpAndSettle();

    expect(find.text('Yedek dosyası seç'), findsOneWidget);
    expect(
      find.text('Başka dosya seç'),
      findsNothing,
      reason: 'pick adımında ikincil aksiyon gösterilmez',
    );

    // Ve gerçekten yeniden seçilebiliyor.
    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();
    expect(docs.pickCount, 2);
  });

  testWidgets('C6: önizleme adımından da dosya seçimine dönülür', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      service: _FakeImportService(
        result: ImportPreview(source: ImportSource.aegis, toAdd: [_acc('a')]),
      ),
      documents: _FakeDocuments(document: _doc()),
      lock: lock,
    );
    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();
    expect(find.text('1 token içe aktarılacak'), findsOneWidget);

    await tester.tap(find.text('Başka dosya seç'));
    await tester.pumpAndSettle();

    expect(find.text('Yedek dosyası seç'), findsOneWidget);
    expect(find.text('1 token içe aktarılacak'), findsNothing);
  });

  testWidgets('C4: onaydan sonra tüketilmiş önizleme EKRANDA KALMAZ', (
    tester,
  ) async {
    // GoRouter yok → `maybePop` false döner ve sayfa açık kalır: eski kodda
    // kullanıcı zaten uygulanmış bir önizlemeye tekrar basabilirdi.
    final repo = _FakeRepo();
    await _pumpPage(
      tester,
      service: _FakeImportService(
        result: ImportPreview(source: ImportSource.aegis, toAdd: [_acc('a')]),
      ),
      documents: _FakeDocuments(document: _doc()),
      lock: lock,
      repo: repo,
    );
    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'İçe aktar'));
    await tester.pumpAndSettle();

    expect(repo.stored, hasLength(1));
    expect(find.text('1 token içe aktarılacak'), findsNothing);
    expect(find.text('Yedek dosyası seç'), findsOneWidget);
  });

  testWidgets('masterKey dispose → yüklü yedeğin düz metni bırakılır (NEW-4b)', (
    tester,
  ) async {
    // `_raw` içe aktarılan dosyanın TAMAMIDIR (her tohum içinde). Kilit
    // kapandığında (arka plan, signOut, reset) masterKey ile AYNI anda düşmeli;
    // bir frame'e (dispose'a) bağlı kalmamalı — bkz. P2-1.
    final service = _FakeImportService(
      result: ImportPreview(source: ImportSource.aegis, toAdd: [_acc('a')]),
    );
    final documents = _FakeDocuments(document: _doc());
    final vault = VaultCubit(_FakeRepo());
    await vault.load();
    addTearDown(vault.close);
    // Ağaç iki kez pump edilir: temizleyici bilinçli olarak `setState`
    // ÇAĞIRMAZ (dispose sonrası da gelebilir), bu yüzden yeniden çizimi test
    // tetikler — gerçekte kilit redirect'i getirir.
    Widget tree() => MultiBlocProvider(
      providers: [
        BlocProvider<VaultLockCubit>.value(value: lock),
        BlocProvider<VaultCubit>.value(value: vault),
      ],
      child: MaterialApp(
        home: ImportPage(service: service, documents: documents),
      ),
    );

    await tester.pumpWidget(tree());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dosya seç'));
    await tester.pumpAndSettle();
    expect(find.text('1 token içe aktarılacak'), findsOneWidget);
    expect(
      lock.plaintextHolders,
      hasLength(1),
      reason: 'sayfa temizleyicisini kaydetmiş olmalı',
    );

    lock.firePlaintextWipe(); // = VaultLockCubit._disposeKey()

    await tester.pumpWidget(tree());
    await tester.pumpAndSettle();
    // `_preview` null'landığı için sayfa dosya seçme adımına düşer — düz metnin
    // (`_raw`, her tohumu içeren TÜM yedek dosyası) gerçekten bırakıldığı budur.
    expect(find.text('1 token içe aktarılacak'), findsNothing);
    expect(find.text('Yedek dosyası seç'), findsOneWidget);
  });
}
