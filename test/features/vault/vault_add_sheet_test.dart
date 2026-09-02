/// Faz 5 Patch 2 (plan §5c) — manuel ekleme sheet'i, Google Authenticator
/// AKTARIM bağlantısı yapıştırıldığında kullanıcıyı QR taramaya yönlendirir.
///
/// `otpauth-migration://` tek bir token DEĞİL, protobuf'lu bir yığındır:
/// `OtpAuthUri.parse` onu anlamsız bir şema hatasıyla reddeder ve kullanıcı
/// nereye gideceğini bilemez. Bu testler yönlendirmeyi ve `add`'in HİÇ
/// çağrılmadığını sabitler.
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
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/data/view_mode_store.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';
import 'package:project_auth/features/vault/presentation/pages/vault_page.dart';

const _migrationUri =
    'otpauth-migration://offline?data=Ci4KCkhlbGxvId6tvu8SEWFsaWNl';
const _singleToken =
    'otpauth://totp/Example:me@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example';

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
  }) async =>
      _d[key];
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
  List<OtpAccount> accounts = [];
  int saves = 0;

  @override
  Future<VaultLoadResult> load() async =>
      VaultLoadResult(accounts: List.of(accounts));
  @override
  Future<void> save(List<OtpAccount> a) async {
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

/// Sheet'in açık olduğunun işareti. ('Kod ekle' başlığı KULLANILMAZ: boş
/// vault'un EmptyState CTA'sı da aynı metni taşır.)
final Finder _sheetTitle = find.text('Demo kodu ekle');

/// Sheet'in bağlantı alanı — VaultPage'in arama alanıyla karışmasın.
final Finder _uriField = find.byWidgetPredicate((w) =>
    w is TextField && w.decoration?.labelText == 'otpauth:// bağlantısı');

/// FAB → "Manuel otpauth:// gir" → sheet açık.
Future<VaultCubit> _openManualSheet(
  WidgetTester tester,
  VaultRepository repo,
) async {
  final vault = VaultCubit(repo)..load();
  addTearDown(vault.close);
  final lock = _FakeLockCubit();
  addTearDown(lock.close);

  await tester.pumpWidget(MultiBlocProvider(
    providers: [
      BlocProvider<VaultCubit>.value(value: vault),
      BlocProvider<VaultLockCubit>.value(value: lock),
    ],
    child: const MediaQuery(
      data: MediaQueryData(disableAnimations: true),
      child: MaterialApp(home: VaultPage()),
    ),
  ));
  await tester.pumpAndSettle();

  await tester.tap(find.text('Ekle'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Manuel otpauth:// gir'));
  await tester.pumpAndSettle();
  expect(_sheetTitle, findsOneWidget);
  return vault;
}

void main() {
  setUp(() {
    if (!locator.isRegistered<OtpGenerator>()) {
      locator.registerLazySingleton<OtpGenerator>(() => const OtpGenerator());
    }
    if (!locator.isRegistered<ViewModeStore>()) {
      locator.registerLazySingleton<ViewModeStore>(
          () => ViewModeStore(storage: _MemStorage()));
    }
  });
  tearDown(GetIt.instance.reset);

  testWidgets('aktarım bağlantısı yapıştırılırsa yönlendirilir, add ÇAĞRILMAZ',
      (tester) async {
    final repo = _FakeRepo();
    final vault = await _openManualSheet(tester, repo);

    await tester.enterText(_uriField, _migrationUri);
    await tester.tap(find.widgetWithText(FilledButton, 'Ekle'));
    await tester.pumpAndSettle();

    expect(
      find.text('Bu bir Google Authenticator aktarım bağlantısı. '
          'Ekle → "QR kod tara" ile okut.'),
      findsOneWidget,
    );
    expect(vault.state.accounts, isEmpty);
    expect(repo.saves, 0, reason: 'hiçbir yazma olmamalı');
    expect(_sheetTitle, findsOneWidget, reason: 'sheet açık kalmalı');
  });

  testWidgets('normal otpauth:// bağlantısı ETKİLENMEZ (guard dar)',
      (tester) async {
    final repo = _FakeRepo();
    final vault = await _openManualSheet(tester, repo);

    await tester.enterText(_uriField, _singleToken);
    await tester.tap(find.widgetWithText(FilledButton, 'Ekle'));
    await tester.pumpAndSettle();

    expect(vault.state.accounts.length, 1);
    expect(repo.saves, 1);
    expect(_sheetTitle, findsNothing, reason: 'sheet kapanmalı');
  });
}
