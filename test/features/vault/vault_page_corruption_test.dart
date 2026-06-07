/// VaultPage corruption UI testleri — banner (devam/onaylı-kaldır) + integrity ekranı.
///
/// libsodium GEREKMEZ: fake VaultRepository + fake VaultLockCubit (lock no-op).
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get_it/get_it.dart';
import 'package:project_auth/core/crypto/crypto_exceptions.dart';
import 'package:project_auth/core/di/locator.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/otp/otp_generator.dart';
import 'package:project_auth/features/vault/data/view_mode_store.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';
import 'package:project_auth/features/vault/presentation/pages/vault_page.dart';

class _MemStorage implements FlutterSecureStorage {
  final Map<String, String> _d = {};
  @override
  Future<String?> read({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async => _d[key];
  @override
  Future<void> write({required String key, required String? value, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async {
    if (value == null) { _d.remove(key); } else { _d[key] = value; }
  }
  @override
  noSuchMethod(Invocation i) => throw UnimplementedError();
}

OtpAccount _acc(String name) => OtpAccount(
      secret: 'JBSWY3DPEHPK3PXP',
      type: OtpType.totp,
      accountName: name,
    );

class _FakeRepo implements VaultRepository {
  List<OtpAccount> accounts;
  int corruptedCount;
  Object? loadError;
  int purgeCalls = 0;

  _FakeRepo({this.accounts = const [], this.corruptedCount = 0, this.loadError});

  @override
  Future<VaultLoadResult> load() async {
    if (loadError != null) throw loadError!;
    return VaultLoadResult(accounts: accounts, corruptedCount: corruptedCount);
  }

  @override
  Future<void> save(List<OtpAccount> a) async => accounts = a;

  @override
  Future<void> purgeCorrupted() async {
    purgeCalls++;
    corruptedCount = 0;
  }
}

/// VaultPage yalnız `lock()` çağırmak için VaultLockCubit'i okur. Fake: gerçek
/// KeyManager olmadan; lock() override edilemez (concrete), bu yüzden gerçek cubit
/// kullanıp state'i unlocked tutmak yerine basit bir test double sağlıyoruz.
class _FakeLockCubit extends Cubit<VaultLockState> implements VaultLockCubit {
  int lockCalls = 0;
  int resetCalls = 0;
  _FakeLockCubit() : super(const VaultLockState.unlocked());

  @override
  void lock({bool immediate = false}) => lockCalls++;

  @override
  Future<void> resetVault() async => resetCalls++;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Widget _wrap(VaultCubit vault, VaultLockCubit lock) => MultiBlocProvider(
      providers: [
        BlocProvider<VaultCubit>.value(value: vault),
        BlocProvider<VaultLockCubit>.value(value: lock),
      ],
      // disableAnimations: CountdownRing'in kritik-saniye pulse'ı (sonsuz repeat)
      // reduced-motion'da kapanır → pumpAndSettle gerçek-zamana bağlı asılmaz
      // (test animasyonu değil corruption UI'ını doğrular).
      child: const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(home: VaultPage()),
      ),
    );

void main() {
  setUp(() {
    // OtpCard → OtpGenerator, VaultPage → ViewModeStore (her ikisi de locator'dan).
    // Saf Dart / in-memory; libsodium gerektirmez.
    if (!locator.isRegistered<OtpGenerator>()) {
      locator.registerLazySingleton<OtpGenerator>(() => const OtpGenerator());
    }
    if (!locator.isRegistered<ViewModeStore>()) {
      locator.registerLazySingleton<ViewModeStore>(
          () => ViewModeStore(storage: _MemStorage()));
    }
  });
  tearDown(GetIt.instance.reset);

  testWidgets('corruptedCount>0 → uyarı banner', (tester) async {
    final repo = _FakeRepo(accounts: [_acc('a')], corruptedCount: 2);
    final vault = VaultCubit(repo)..load();
    addTearDown(vault.close);
    final lock = _FakeLockCubit();
    addTearDown(lock.close);

    await tester.pumpWidget(_wrap(vault, lock));
    await tester.pumpAndSettle();

    expect(find.textContaining('2 kayıt çözülemedi'), findsOneWidget);
    expect(find.text('Yine de devam et'), findsOneWidget);
    expect(find.text('Bozuk kayıtları kaldır'), findsOneWidget);
  });

  testWidgets('"Yine de devam et" → banner gizlenir, token kalır',
      (tester) async {
    final repo = _FakeRepo(accounts: [_acc('a')], corruptedCount: 1);
    final vault = VaultCubit(repo)..load();
    addTearDown(vault.close);
    final lock = _FakeLockCubit();
    addTearDown(lock.close);

    await tester.pumpWidget(_wrap(vault, lock));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Yine de devam et'));
    await tester.pumpAndSettle();

    expect(find.textContaining('çözülemedi'), findsNothing);
    expect(repo.purgeCalls, 0); // bozuk kayıtlar silinmedi
  });

  testWidgets('"Bozuk kayıtları kaldır" → onay diyaloğu → purgeCorrupted',
      (tester) async {
    final repo = _FakeRepo(accounts: [_acc('a')], corruptedCount: 1);
    final vault = VaultCubit(repo)..load();
    addTearDown(vault.close);
    final lock = _FakeLockCubit();
    addTearDown(lock.close);

    await tester.pumpWidget(_wrap(vault, lock));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bozuk kayıtları kaldır'));
    await tester.pumpAndSettle();
    // Onaysız iptal → purge çağrılmaz.
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();
    expect(repo.purgeCalls, 0);

    // Tekrar aç → onayla → purge çağrılır.
    await tester.tap(find.text('Bozuk kayıtları kaldır'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kaldır'));
    await tester.pumpAndSettle();
    expect(repo.purgeCalls, 1);
  });

  testWidgets('VaultIntegrityException → integrity ekranı (boş-durum DEĞİL)',
      (tester) async {
    final repo = _FakeRepo(loadError: const VaultIntegrityException('toptan'));
    final vault = VaultCubit(repo)..load();
    addTearDown(vault.close);
    final lock = _FakeLockCubit();
    addTearDown(lock.close);

    await tester.pumpWidget(_wrap(vault, lock));
    await tester.pumpAndSettle();

    expect(find.text('Vault açılamadı'), findsOneWidget);
    expect(find.text('Henüz kod yok'), findsNothing); // boş-durum DEĞİL

    await tester.tap(find.text('Vault\'u yeniden aç'));
    await tester.pumpAndSettle();
    expect(lock.lockCalls, 1);
  });

  testWidgets('integrity ekranı → "Vault\'u sıfırla" çift onaylı → resetVault '
      '(review P3)', (tester) async {
    final repo = _FakeRepo(loadError: const VaultIntegrityException('toptan'));
    final vault = VaultCubit(repo)..load();
    addTearDown(vault.close);
    final lock = _FakeLockCubit();
    addTearDown(lock.close);

    await tester.pumpWidget(_wrap(vault, lock));
    await tester.pumpAndSettle();

    // Onaysız iptal → reset çağrılmaz.
    await tester.tap(find.text('Vault\'u sıfırla'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();
    expect(lock.resetCalls, 0);

    // Tekrar aç → onayla → resetVault çağrılır (destructive, çift onaylı).
    await tester.tap(find.text('Vault\'u sıfırla'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sıfırla'));
    await tester.pumpAndSettle();
    expect(lock.resetCalls, 1);
  });

  testWidgets('integrity ekranında ekleme FAB\'ı GİZLİ — onaysız overwrite yok '
      '(review P1)', (tester) async {
    final repo = _FakeRepo(loadError: const VaultIntegrityException('toptan'));
    final vault = VaultCubit(repo)..load();
    addTearDown(vault.close);
    final lock = _FakeLockCubit();
    addTearDown(lock.close);

    await tester.pumpWidget(_wrap(vault, lock));
    await tester.pumpAndSettle();

    // Bütünlük ekranı görünür; "Ekle" FAB'ı YOK (add yolu kapalı → diskteki
    // bozuk vault onaysız ezilemez). Sağlam vault'ta FAB normalde görünür.
    expect(find.text('Vault açılamadı'), findsOneWidget);
    expect(find.widgetWithText(FloatingActionButton, 'Ekle'), findsNothing);
  });

  testWidgets('sağlam vault\'ta ekleme FAB\'ı görünür (kontrol)',
      (tester) async {
    final repo = _FakeRepo(accounts: [_acc('a')]);
    final vault = VaultCubit(repo)..load();
    addTearDown(vault.close);
    final lock = _FakeLockCubit();
    addTearDown(lock.close);

    await tester.pumpWidget(_wrap(vault, lock));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FloatingActionButton, 'Ekle'), findsOneWidget);
  });
}
