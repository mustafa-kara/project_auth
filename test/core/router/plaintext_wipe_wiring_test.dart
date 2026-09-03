/// P2-1 kablolamasının UÇTAN UCA testi (doğrulama NEW-4).
///
/// Parçalar tek tek pinlenmişti (`registerPlaintextHolder` cubit testinde,
/// `wipe()` VaultCubit testinde) ama ARALARINDAKİ bağ değildi: gerçek
/// `ShellRoute`'un `_PlaintextWipeScope`'u `VaultCubit.wipe`'ı kilit cubit'ine
/// kaydediyor mu, subtree sökülürken kaydı geri alıyor mu?
///
/// Kritik nokta ve testin tüm anlamı: **frame PUMP EDİLMEDEN**. P2-1'in iddiası
/// tam olarak budur — `lock(immediate: true)` arka planda çağrılır ve orada bir
/// frame GARANTİ DEĞİLDİR; plaintext subtree teardown'a (yani bir frame'e)
/// bağlıysa anahtar gider, tohumlar kalır.
///
/// Kilit cubit'i GERÇEK olanıdır (bağımlılıkları sahte): sahte bir cubit yalnız
/// kendi sahte `lock()`'unu doğrulardı, kablolamayı değil. libsodium/Supabase
/// GEREKMEZ.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:project_auth/core/di/locator.dart';
import 'package:project_auth/core/otp/otp_generator.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/core/crypto/key_attributes.dart';
import 'package:project_auth/core/crypto/key_handle.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/core/router/app_router.dart';
import 'package:project_auth/features/account/presentation/bloc/session_cubit.dart';
import 'package:project_auth/features/account/presentation/bloc/session_state.dart';
import 'package:project_auth/features/auth/data/key_attributes_store.dart';
import 'package:project_auth/features/auth/domain/biometric_service.dart';
import 'package:project_auth/features/auth/domain/key_manager.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/vault/data/live_sync_pref_store.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/data/view_mode_store.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';

// --- Fakes ---

class _FakeKeyHandle implements KeyHandle {
  bool disposed = false;
  @override
  void dispose() => disposed = true;
}

class _NoBiometric implements BiometricService {
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<void> enroll(Uint8List keyBytes) async {}
  @override
  Future<Uint8List> retrieve() async => Uint8List(0);
  @override
  Future<void> disable() async {}
}

KeyAttributes _attrs() {
  final blob = EncryptedBlob(nonce: Uint8List(24), ciphertext: Uint8List(16));
  return KeyAttributes(
    kdfSalt: Uint8List(KeyAttributes.saltBytes),
    kdfOps: 2,
    kdfMem: 67108864,
    encryptedMasterKey: blob,
    recoveryEncryptedMasterKey: blob,
  );
}

class _FakeKeyManager implements KeyManager {
  final List<_FakeKeyHandle> issued = [];

  _FakeKeyHandle _newKey() {
    final k = _FakeKeyHandle();
    issued.add(k);
    return k;
  }

  @override
  Future<KeyHandle> unlock(KeyAttributes attrs, String password) async =>
      _newKey();

  @override
  Future<SetupResult> setup(String masterPassword) async => (
    attrs: _attrs(),
    recoveryMnemonic: List.generate(24, (i) => 'word$i'),
    masterKey: _newKey(),
  );

  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

/// `attrs` var → bootstrap `locked` verir; `unlock` ile `unlocked`'a geçilir.
class _FakeAttrsStore implements KeyAttributesStore {
  @override
  Future<KeyAttributes?> read() async => _attrs();
  @override
  Future<void> write(KeyAttributes attrs) async {}
  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

class _FakeSession extends Cubit<SessionState> implements SessionCubit {
  _FakeSession() : super(const SessionState(status: SessionStatus.signedIn));
  @override
  noSuchMethod(Invocation i) {}
}

/// İki token'lı bellek-içi vault (secure_storage'a dokunmaz).
class _SeededRepo implements VaultRepository {
  static final accounts = <OtpAccount>[
    OtpAccount(
      secret: 'JBSWY3DPEHPK3PXP',
      type: OtpType.totp,
      issuer: 'GitHub',
      accountName: 'octocat',
    ),
    OtpAccount(
      secret: 'JBSWY3DPEHPK3PXQ',
      type: OtpType.totp,
      issuer: 'GitLab',
      accountName: 'tanuki',
    ),
  ];

  @override
  Future<VaultLoadResult> load() async =>
      VaultLoadResult(accounts: List.of(accounts));
  @override
  Future<void> save(List<OtpAccount> accounts) async {}
  @override
  Future<void> purgeCorrupted() async {}
}

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
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

/// Sabit sayıda frame ilerletir. `pumpAndSettle` DEĞİL: kilit sonrası subtree
/// teardown'ında ağaç "durulmuyor" (1 Hz OtpCard sayacı + route geçişi) ve test
/// gerçek zamana bağlı asılıyor.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  late _FakeKeyManager km;
  late VaultLockCubit lock;
  late _FakeSession session;
  late VaultCubit vault;

  /// Shell mount edildiyse `BlocProvider` [vault]'u KENDİSİ kapatır; tearDown'da
  /// ikinci bir `close()` bloc'un `done` future'ında asılır.
  var shellMounted = false;

  setUp(() {
    // VaultPage/OtpCard locator'dan okur (saf Dart; libsodium gerekmez).
    if (!locator.isRegistered<OtpGenerator>()) {
      locator.registerLazySingleton<OtpGenerator>(() => const OtpGenerator());
    }
    if (!locator.isRegistered<ViewModeStore>()) {
      locator.registerLazySingleton<ViewModeStore>(
        () => ViewModeStore(storage: _MemStorage()),
      );
    }
    shellMounted = false;
    km = _FakeKeyManager();
    lock = VaultLockCubit(
      keyManager: km,
      attrsStore: _FakeAttrsStore(),
      biometric: _NoBiometric(),
      migrate: (_) async {},
      deleteKeys: (_) async {},
    );
    session = _FakeSession();
    vault = VaultCubit(_SeededRepo());
  });

  tearDown(() async {
    await lock.close();
    await session.close();
    if (!shellMounted) await vault.close();
    await GetIt.instance.reset();
  });

  /// Gerçek router + ShellRoute; VaultCubit dışarıdan verilir ki test onu
  /// subtree söküldükten SONRA da inceleyebilsin.
  Future<AppRouterBundle> mountShell(WidgetTester tester) async {
    shellMounted = true;
    final bundle = createAppRouter(
      lock,
      session: session,
      vaultCubitBuilder: () => vault..load(),
      viewModeStoreBuilder: () => ViewModeStore(storage: _MemStorage()),
      liveSyncStoreBuilder: () => LiveSyncPrefStore(storage: _MemStorage()),
    );
    addTearDown(bundle.dispose);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<VaultLockCubit>.value(value: lock),
          BlocProvider<SessionCubit>.value(value: session),
        ],
        // disableAnimations: CountdownRing'in sonsuz pulse'ı reduced-motion'da
        // kapanır (kart animasyonları frame zinciri kurmasın).
        child: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp.router(routerConfig: bundle.router),
        ),
      ),
    );
    await _settle(tester);
    return bundle;
  }

  Future<void> unlockAndMount(WidgetTester tester) async {
    await lock.bootstrap();
    await lock.unlock('parola123');
    expect(lock.state.status, VaultLockStatus.unlocked);
    await mountShell(tester);
    expect(
      vault.state.accounts,
      hasLength(2),
      reason: 'shell mount + load → plaintext bellekte',
    );
  }

  testWidgets(
    'lock(immediate: true) → FRAME BEKLEMEDEN accounts boşalır (NEW-4a)',
    (tester) async {
      await unlockAndMount(tester);

      lock.lock(immediate: true);

      // TEK BİR pump YOK — P2-1'in iddiası tam olarak bu.
      expect(
        vault.state.accounts,
        isEmpty,
        reason: 'plaintext masterKey ile AYNI anda düşmeli',
      );
      expect(lock.state.status, VaultLockStatus.locked);
      expect(km.issued.single.disposed, isTrue);

      await _settle(tester); // teardown olduğu gibi çalışmaya devam eder
      expect(vault.state.accounts, isEmpty);
    },
  );

  testWidgets('lock(immediate: false) → post-frame\'de accounts boşalır', (
    tester,
  ) async {
    await unlockAndMount(tester);

    lock.lock(); // interaktif "Kilitle": yumuşak teardown
    expect(lock.state.status, VaultLockStatus.locking);

    await _settle(tester);
    expect(lock.state.status, VaultLockStatus.locked);
    expect(vault.state.accounts, isEmpty);
    expect(km.issued.single.disposed, isTrue);
  });

  testWidgets(
    'subtree söküldükten sonra kayıt geri alınır (sarkan referans yok)',
    (tester) async {
      await unlockAndMount(tester);

      lock.lock(immediate: true);
      await _settle(tester); // ShellRoute sökülür → _unregister çalışır

      // Kilitliyken ikinci bir dispose sökülmüş cubit'e DOKUNMAMALI.
      await lock.unlock('parola123');
      expect(lock.state.status, VaultLockStatus.unlocked);
      lock.lock(immediate: true);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancelSetup() da tutucuları çalıştırır', (tester) async {
    // setupPending → cancelSetup `_disposeKey()` üzerinden geçer. Shell yalnız
    // unlocked iken mount olduğu için tutucu doğrudan kaydedilir (kablolamanın
    // kendisi yukarıdaki testlerde pinli).
    await lock.beginSetup('parola123');
    expect(lock.state.status, VaultLockStatus.setupPending);
    // Kayıt beginSetup'tan SONRA: beginSetup da (setup-restart için) _disposeKey
    // çağırır, o sayım bu testin konusu değil.
    var wiped = 0;
    lock.registerPlaintextHolder(() => wiped++);

    lock.cancelSetup();
    expect(wiped, 1);
    expect(lock.state.status, VaultLockStatus.uninitialized);
  });
}
