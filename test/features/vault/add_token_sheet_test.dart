/// Faz 5 Patch 3 (plan §5 D4) — `AddTokenSheet`: YAPIŞTIRILAN Google
/// Authenticator aktarım bağlantısı sheet'in içinde işlenir.
///
/// Patch 2'de burası kullanıcıyı kameraya yönlendiriyordu; artık `otpauth-
/// migration://` metni [MigrationScanController]'a gider, eksik aktarımda
/// ilerleme bandı, tamamlanınca ortak önizleme çıkar. QR'ı taratamayan (tek
/// cihazlı, kamerasız) kullanıcının TEK yolu bu.
///
/// Aktarım testleri sheet'i DOĞRUDAN pump eder ve migration beynini enjekte
/// eder: böylece testler protobuf çözücünün gövdesinden ve DI'dan bağımsız
/// kalır — sınanan sheet'in davranışı. Tek-token yolu ise VaultPage'in menüsü
/// üzerinden sürülür (gerçek kullanıcı yolu, guard'ın dar kaldığının kanıtı).
///
/// libsodium GEREKMEZ: fake VaultRepository + fake VaultLockCubit.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:project_auth/core/di/locator.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/otp/otp_generator.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/import_export/domain/import_exceptions.dart';
import 'package:project_auth/features/import_export/domain/import_models.dart';
import 'package:project_auth/features/import_export/domain/import_service.dart';
import 'package:project_auth/features/scan/presentation/migration_scan_controller.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/data/view_mode_store.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';
import 'package:project_auth/features/vault/presentation/pages/vault_page.dart';
import 'package:project_auth/features/vault/presentation/widgets/add_token_sheet.dart';

const _migrationUri =
    'otpauth-migration://offline?data=Ci4KCkhlbGxvId6tvu8SEWFsaWNl';
const _migrationUri2 = 'otpauth-migration://offline?data=BBBB';
const _singleToken =
    'otpauth://totp/Example:me@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example';

OtpAccount _acc(String name) => OtpAccount(
  secret: 'JBSWY3DPEHPK3PXP',
  type: OtpType.totp,
  accountName: name,
);

class _MemStorage implements FlutterSecureStorage {
  final Map<String, String> _d = {};
  @override
  Future<String?> read({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async => _d[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async {
    if (value == null) {
      _d.remove(key);
    } else {
      _d[key] = value;
    }
  }

  @override
  noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _FakeRepo implements VaultRepository {
  _FakeRepo({this.saveError});

  final Object? saveError;
  List<OtpAccount> accounts = [];
  int saves = 0;

  @override
  Future<VaultLoadResult> load() async =>
      VaultLoadResult(accounts: List.of(accounts));
  @override
  Future<void> save(List<OtpAccount> a) async {
    if (saveError != null) throw saveError!;
    saves++;
    accounts = List.of(a);
  }

  @override
  Future<void> purgeCorrupted() async {}
}

class _FakeLockCubit extends Cubit<VaultLockState> implements VaultLockCubit {
  _FakeLockCubit() : super(const VaultLockState.unlocked());
  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// `MigrationScanController` somut sınıf → `implements` ile sahtelenir.
class _FakeMigration implements MigrationScanController {
  _FakeMigration({
    this.script = const {},
    this.previewResult,
    this.previewError,
  });

  /// Yapıştırılan ham metin → döndürülecek olay.
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

/// Sheet'in bağlantı alanı — VaultPage'in arama alanıyla karışmasın.
final Finder _uriField = find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == 'otpauth:// bağlantısı',
);

/// Sheet'in açık olduğunun işareti. ('Kod ekle' başlığı KULLANILMAZ: boş
/// vault'un EmptyState CTA'sı da aynı metni taşır.)
final Finder _sheetTitle = find.text('Demo kodu ekle');

/// FAB → "Manuel otpauth:// gir" → sheet açık (gerçek kullanıcı yolu).
Future<VaultCubit> _openManualSheet(
  WidgetTester tester,
  VaultRepository repo,
) async {
  final vault = VaultCubit(repo)..load();
  addTearDown(vault.close);
  final lock = _FakeLockCubit();
  addTearDown(lock.close);

  await tester.pumpWidget(
    MultiBlocProvider(
      providers: [
        BlocProvider<VaultCubit>.value(value: vault),
        BlocProvider<VaultLockCubit>.value(value: lock),
      ],
      child: const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(home: VaultPage()),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.text('Ekle'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Manuel otpauth:// gir'));
  await tester.pumpAndSettle();
  expect(_sheetTitle, findsOneWidget);
  return vault;
}

/// Sheet'i doğrudan bir modal bottom sheet içinde açar (migration beyni
/// enjekte edilmiş). VaultPage'e gerek yok: sınanan sheet.
Future<VaultCubit> _pumpSheet(
  WidgetTester tester, {
  required _FakeMigration migration,
  _FakeRepo? repo,
  List<OtpAccount> existing = const [],
}) async {
  final vault = VaultCubit(repo ?? _FakeRepo());
  await vault.load();
  addTearDown(vault.close);
  if (existing.isNotEmpty) await vault.addAll(existing);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (c) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: c,
              isScrollControlled: true,
              builder: (_) =>
                  AddTokenSheet(cubit: vault, debugMigration: migration),
            ),
            child: const Text('sheet aç'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('sheet aç'));
  await tester.pumpAndSettle();
  expect(_uriField, findsOneWidget);
  return vault;
}

Future<void> _paste(WidgetTester tester, String text) async {
  await tester.enterText(_uriField, text);
  await tester.tap(find.widgetWithText(FilledButton, 'Ekle'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    if (!locator.isRegistered<OtpGenerator>()) {
      locator.registerLazySingleton<OtpGenerator>(() => const OtpGenerator());
    }
    if (!locator.isRegistered<ViewModeStore>()) {
      locator.registerLazySingleton<ViewModeStore>(
        () => ViewModeStore(storage: _MemStorage()),
      );
    }
  });
  tearDown(GetIt.instance.reset);

  testWidgets('bozuk aktarım bağlantısı → sabit hata, add ÇAĞRILMAZ', (
    tester,
  ) async {
    final repo = _FakeRepo();
    final migration = _FakeMigration(
      script: const {_migrationUri: MigrationMalformedQr()},
    );
    final vault = await _pumpSheet(tester, migration: migration, repo: repo);

    await _paste(tester, _migrationUri);

    expect(
      find.text(
        'Bu bağlantı bir Google Authenticator aktarım bağlantısı '
        'değil ya da bozuk.',
      ),
      findsOneWidget,
    );
    expect(vault.state.accounts, isEmpty);
    expect(repo.saves, 0, reason: 'hiçbir yazma olmamalı');
    expect(_uriField, findsOneWidget, reason: 'sheet açık kalmalı');
  });

  testWidgets('hata metni yapıştırılan bağlantıyı TAŞIMAZ', (tester) async {
    final migration = _FakeMigration(
      script: const {_migrationUri: MigrationMalformedQr()},
    );
    await _pumpSheet(tester, migration: migration);

    await _paste(tester, _migrationUri);

    expect(find.textContaining('Ci4KCkhlbGxv'), findsNothing);
  });

  testWidgets('tek bağlantılık aktarım → doğrudan önizleme', (tester) async {
    final migration = _FakeMigration(
      script: const {_migrationUri: MigrationScanComplete(1, 1)},
      previewResult: ImportPreview(
        source: ImportSource.googleAuth,
        toAdd: [_acc('a@x'), _acc('b@x')],
      ),
    );
    final vault = await _pumpSheet(tester, migration: migration);

    await _paste(tester, _migrationUri);

    expect(find.text('2 token içe aktarılacak'), findsOneWidget);
    expect(find.text('1/1 bağlantı'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'İçe aktar'), findsOneWidget);
    expect(migration.lastExisting, isEmpty);
    expect(vault.state.accounts, isEmpty, reason: 'onay bekleniyor');
  });

  testWidgets('eksik aktarım → ilerleme bandı, alan temizlenir', (
    tester,
  ) async {
    final migration = _FakeMigration(
      script: const {_migrationUri: MigrationBatchAdded(1, 2)},
    );
    await _pumpSheet(tester, migration: migration);

    await _paste(tester, _migrationUri);

    expect(find.text('1/2 bağlantı eklendi'), findsOneWidget);
    expect(find.text('Kalan bağlantıları da yapıştır'), findsOneWidget);
    expect(find.text('Bu kadar yeter'), findsOneWidget);
    expect(find.text('Baştan başla'), findsOneWidget);
    expect(
      tester.widget<TextField>(_uriField).controller?.text,
      isEmpty,
      reason: 'yapıştırılan bağlantı canlı secret — alanda kalmamalı',
    );
  });

  testWidgets('kalan bağlantı da yapıştırılınca önizleme çıkar', (
    tester,
  ) async {
    final migration = _FakeMigration(
      script: const {
        _migrationUri: MigrationBatchAdded(1, 2),
        _migrationUri2: MigrationScanComplete(2, 2),
      },
      previewResult: ImportPreview(
        source: ImportSource.googleAuth,
        toAdd: [_acc('a@x')],
      ),
    );
    await _pumpSheet(tester, migration: migration);

    await _paste(tester, _migrationUri);
    expect(find.text('1/2 bağlantı eklendi'), findsOneWidget);

    await _paste(tester, _migrationUri2);

    expect(find.textContaining('bağlantı eklendi'), findsNothing);
    expect(find.text('1 token içe aktarılacak'), findsOneWidget);
    expect(find.text('2/2 bağlantı'), findsOneWidget);
  });

  testWidgets('onay → tek addAll, snackbar, sheet kapanır', (tester) async {
    final repo = _FakeRepo();
    final migration = _FakeMigration(
      script: const {_migrationUri: MigrationScanComplete(1, 1)},
      previewResult: ImportPreview(
        source: ImportSource.googleAuth,
        toAdd: [_acc('a@x'), _acc('b@x')],
      ),
    );
    final vault = await _pumpSheet(tester, migration: migration, repo: repo);

    await _paste(tester, _migrationUri);
    await tester.tap(find.widgetWithText(FilledButton, 'İçe aktar'));
    await tester.pumpAndSettle();

    expect(vault.state.accounts.length, 2);
    expect(repo.saves, 1, reason: 'tek persist');
    expect(find.text('2 token eklendi'), findsOneWidget);
    expect(_uriField, findsNothing, reason: 'sheet kapanmalı');
    expect(
      migration.resets,
      greaterThanOrEqualTo(1),
      reason: 'secret\'lar vault\'ta — bellekte tutma',
    );
  });

  testWidgets('kaydedilemezse sheet KAPANMAZ', (tester) async {
    final repo = _FakeRepo(saveError: StateError('disk'));
    final migration = _FakeMigration(
      script: const {_migrationUri: MigrationScanComplete(1, 1)},
      previewResult: ImportPreview(
        source: ImportSource.googleAuth,
        toAdd: [_acc('a@x')],
      ),
    );
    await _pumpSheet(tester, migration: migration, repo: repo);

    await _paste(tester, _migrationUri);
    await tester.tap(find.widgetWithText(FilledButton, 'İçe aktar'));
    await tester.pumpAndSettle();

    expect(find.text('Tokenlar kaydedilemedi — tekrar dene.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'İçe aktar'), findsOneWidget);
  });

  testWidgets('yabancı aktarımın bağlantısı → baştan başla diyaloğu', (
    tester,
  ) async {
    final migration = _FakeMigration(
      script: const {
        _migrationUri: MigrationBatchAdded(1, 2),
        _migrationUri2: MigrationDifferentBatch(),
      },
    );
    await _pumpSheet(tester, migration: migration);

    await _paste(tester, _migrationUri);
    await _paste(tester, _migrationUri2);

    expect(
      find.text(
        'Bu bağlantı farklı bir dışa aktarmaya ait. '
        'Baştan başlansın mı?',
      ),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Baştan başla'));
    await tester.pumpAndSettle();

    expect(migration.resets, 1);
    expect(
      find.textContaining('bağlantı eklendi'),
      findsNothing,
      reason: 'sayaçlar sıfırlandı',
    );
  });

  testWidgets('aynı bağlantı ikinci kez → uyarı, sayaç değişmez', (
    tester,
  ) async {
    final migration = _FakeMigration(
      script: const {
        _migrationUri: MigrationBatchAdded(1, 2),
        _migrationUri2: MigrationDuplicateScan(),
      },
    );
    await _pumpSheet(tester, migration: migration);

    await _paste(tester, _migrationUri);
    await _paste(tester, _migrationUri2);

    expect(find.text('Bu bağlantı zaten eklendi'), findsOneWidget);
    expect(find.text('1/2 bağlantı eklendi'), findsOneWidget);
  });

  testWidgets('kapasite aşımı → "çok fazla hesap" uyarısı', (tester) async {
    final migration = _FakeMigration(
      script: const {_migrationUri: MigrationScanFull()},
    );
    await _pumpSheet(tester, migration: migration);

    await _paste(tester, _migrationUri);

    expect(find.text('Bu aktarımda çok fazla hesap var.'), findsOneWidget);
  });

  testWidgets('önizlemede token yoksa hata gösterilir', (tester) async {
    final migration = _FakeMigration(
      script: const {_migrationUri: MigrationScanComplete(1, 1)},
      previewError: const EmptyImportException(),
    );
    await _pumpSheet(tester, migration: migration);

    await _paste(tester, _migrationUri);

    expect(
      find.text('Bu bağlantılarda içe aktarılacak token bulunamadı.'),
      findsOneWidget,
    );
  });

  testWidgets('önizleme vault\'taki tokenlarla dedupe edilir', (tester) async {
    final migration = _FakeMigration(
      script: const {_migrationUri: MigrationScanComplete(1, 1)},
      previewResult: ImportPreview(
        source: ImportSource.googleAuth,
        toAdd: [_acc('yeni@x')],
      ),
    );
    await _pumpSheet(
      tester,
      migration: migration,
      existing: [_acc('mevcut@x')],
    );

    await _paste(tester, _migrationUri);

    expect(
      migration.lastExisting?.length,
      1,
      reason: 'vault\'taki token dedupe girdisi olmalı',
    );
  });

  testWidgets('normal otpauth:// bağlantısı ETKİLENMEZ (guard dar)', (
    tester,
  ) async {
    final repo = _FakeRepo();
    final vault = await _openManualSheet(tester, repo);

    await tester.enterText(_uriField, _singleToken);
    await tester.tap(find.widgetWithText(FilledButton, 'Ekle'));
    await tester.pumpAndSettle();

    expect(vault.state.accounts.length, 1);
    expect(repo.saves, 1);
    expect(_sheetTitle, findsNothing, reason: 'sheet kapanmalı');
  });

  testWidgets('geçersiz otpauth:// → parse hatası, DI\'ya dokunulmaz', (
    tester,
  ) async {
    final repo = _FakeRepo();
    final vault = await _openManualSheet(tester, repo);

    // `ImportService` KAYITLI DEĞİL: tek-token yolu migration beynini tembel
    // bırakır, yoksa bu test locator hatasıyla düşerdi.
    await tester.enterText(_uriField, 'https://example.com');
    await tester.tap(find.widgetWithText(FilledButton, 'Ekle'));
    await tester.pumpAndSettle();

    expect(vault.state.accounts, isEmpty);
    expect(repo.saves, 0);
    expect(_sheetTitle, findsOneWidget);
  });
}
