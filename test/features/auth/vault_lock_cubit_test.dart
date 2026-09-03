/// VaultLockCubit testleri — durum makinesi, setup-commit, unlock/recover,
/// lifecycle lock (paused/inactive), reset, keyAttributesCorrupted.
///
/// libsodium GEREKMEZ: `KeyManager` ve `KeyHandle` fake'lenir (state-machine +
/// sahiplik/dispose mantığı host'ta `flutter test` ile koşar). Migration de sahte
/// kanca; gerçek `VaultMigration`/crypto integration_test'te.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/crypto_exceptions.dart';
import 'package:project_auth/core/crypto/encrypted_blob.dart';
import 'package:project_auth/core/crypto/key_attributes.dart';
import 'package:project_auth/core/crypto/key_handle.dart';
import 'package:project_auth/features/account/data/attrs_dirty_store.dart';
import 'package:project_auth/features/account/data/reset_pending_store.dart';
import 'package:project_auth/features/account/domain/key_attributes_repository.dart';
import 'package:project_auth/features/account/domain/sync_exceptions.dart';
import 'package:project_auth/features/auth/data/key_attributes_store.dart';
import 'package:project_auth/features/auth/domain/biometric_exceptions.dart';
import 'package:project_auth/features/auth/domain/biometric_service.dart';
import 'package:project_auth/features/auth/domain/key_manager.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/vault/domain/raw_token_record.dart';
import 'package:project_auth/features/vault/domain/remote_token_repository.dart';

// --- Fakes ---

class FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> data = {};

  /// true ise `write` IO hatası fırlatır (commitSetup write-fail testi).
  bool failWrites = false;

  /// Verilirse `write` bu future bitene kadar askıya alınır — gate çözüldükten
  /// SONRA (varsa) `failWrites` kontrolü yapılır. write-fail + background
  /// kesişim testi: write askıdayken `onAppBackgrounded(paused: true)` tetikle, sonra throw.
  Future<void>? writeGate;

  /// Verilirse `read` bunu FIRLATIR (P1-2: `resetOnError: false` ile Keystore/
  /// Keychain hatası artık sessiz null yerine `PlatformException` olarak gelir).
  Object? readError;

  @override
  Future<String?> read({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async {
    if (readError != null) throw readError!;
    return data[key];
  }

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
    if (writeGate != null) await writeGate;
    if (failWrites) throw Exception('secure storage write IO hatası (test)');
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async {
    data.remove(key);
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeSecureStorage: ${invocation.memberName}');
}

class FakeKeyHandle implements KeyHandle {
  bool disposed = false;
  @override
  void dispose() => disposed = true;
}

/// Sahte biyometri servisi (Patch 5). Gerçek OS/local_auth gerektirmez.
class FakeBiometricService implements BiometricService {
  bool available;

  /// retrieve() davranışı: hata fırlatmak için set edilir (Canceled/Lockout/...).
  Exception? retrieveError;

  /// retrieve() bu future bitene kadar askıya alınır (background-yarış testi:
  /// retrieve OS prompt'unda beklerken onAppBackgrounded tetiklenir).
  Future<void>? retrieveGate;

  /// retrieve() başarılıysa dönecek byte'lar (default 32-bayt).
  Uint8List storedKey;

  /// enroll/disable çağrı sayaçları + enroll IO hatası tetiği.
  int enrollCount = 0;
  int disableCount = 0;
  bool enrollThrows = false;

  FakeBiometricService({
    this.available = true,
    this.retrieveError,
    this.retrieveGate,
    Uint8List? storedKey,
  }) : storedKey = storedKey ?? Uint8List.fromList(List.filled(32, 7));

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<void> enroll(Uint8List keyBytes) async {
    enrollCount++;
    if (enrollThrows) throw const BiometricStorageError('enroll fail (test)');
  }

  @override
  Future<Uint8List> retrieve() async {
    if (retrieveGate != null) await retrieveGate;
    if (retrieveError != null) throw retrieveError!;
    return Uint8List.fromList(storedKey);
  }

  @override
  Future<void> disable() async => disableCount++;
}

/// Sahte attrs — gerçek bloblar gerekmiyor (KeyManager fake'lendi). Geçerli salt
/// (16 byte) ile KeyAttributes ctor validasyonunu geçer.
KeyAttributes _fakeAttrs() {
  final blob = EncryptedBlob(nonce: Uint8List(24), ciphertext: Uint8List(16));
  return KeyAttributes(
    kdfSalt: Uint8List(KeyAttributes.saltBytes),
    kdfOps: 2,
    kdfMem: 67108864,
    encryptedMasterKey: blob,
    recoveryEncryptedMasterKey: blob,
  );
}

class FakeKeyManager implements KeyManager {
  final List<String> mnemonic;
  bool wrongPassword;
  bool wrongRecovery;
  final List<FakeKeyHandle> issued = [];

  /// Verilirse `setup()` bu future bitene kadar askıya alınır (beginSetup
  /// arka-plan yarışı testi: KeyManager.setup Argon2id'de beklerken background).
  Future<void>? setupGate;

  FakeKeyManager({
    List<String>? mnemonic,
    this.wrongPassword = false,
    this.wrongRecovery = false,
    this.setupGate,
  }) : mnemonic = mnemonic ?? List.generate(24, (i) => 'word$i');

  FakeKeyHandle _newKey() {
    final k = FakeKeyHandle();
    issued.add(k);
    return k;
  }

  @override
  Future<SetupResult> setup(String masterPassword) async {
    if (setupGate != null) await setupGate;
    return (
      attrs: _fakeAttrs(),
      recoveryMnemonic: mnemonic,
      masterKey: _newKey(),
    );
  }

  @override
  Future<KeyHandle> unlock(KeyAttributes attrs, String masterPassword) async {
    if (wrongPassword) throw const WrongPasswordException();
    return _newKey();
  }

  @override
  Future<KeyHandle> recoverUnlock(
    KeyAttributes attrs,
    List<String> mnemonic,
  ) async {
    if (wrongRecovery) throw const WrongRecoveryKeyException();
    return _newKey();
  }

  @override
  Future<KeyAttributes> changePassword(
    KeyAttributes attrs,
    KeyHandle masterKey,
    String newPassword,
  ) async => _fakeAttrs();

  /// bmk eklenmiş attrs + 32-bayt sahte key. Gerçek wrap yok (KeyManager fake).
  bool biometricUnwrapFails = false;

  @override
  BiometricEnrollResult enrollBiometric(
    KeyAttributes attrs,
    KeyHandle masterKey,
  ) {
    final bmkBlob = EncryptedBlob(
      nonce: Uint8List(24),
      ciphertext: Uint8List(16),
    );
    return (
      attrs: attrs.copyWith(biometricEncryptedMasterKey: bmkBlob),
      biometricKeyBytes: Uint8List.fromList(List.filled(32, 5)),
    );
  }

  @override
  KeyHandle biometricUnlock(KeyAttributes attrs, Uint8List biometricKeyBytes) {
    if (biometricUnwrapFails) throw const BiometricUnwrapException();
    return _newKey();
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeKeyManager: ${invocation.memberName}');
}

VaultLockCubit _build(
  FakeKeyManager km,
  KeyAttributesStore store, {
  List<String>? migrated,
  List<String>? deletedSink,
  bool migrationFails = false,
  Future<void>? migrateGate,
  BiometricService? biometric,
  KeyAttributesRepository? remoteRepo,
  RemoteTokenRepository? remoteTokenRepo,
  String? uid,
  AttrsDirtyStore? attrsDirtyStore,
  ResetPendingStore? resetPendingStore,
  DateTime Function()? now,
}) {
  final mig = migrated ?? <String>[];
  return VaultLockCubit(
    keyManager: km,
    attrsStore: store,
    biometric: biometric ?? FakeBiometricService(),
    migrate: (_) async {
      // migrateGate verildiyse migration burada askıya alınır (P1 yarış testleri:
      // işlem _migrate'te beklerken onAppBackgrounded tetiklenir).
      if (migrateGate != null) await migrateGate;
      if (migrationFails) throw StateError('migration patladı');
      mig.add('migrated');
    },
    deleteKeys: (keys) async {
      deletedSink?.addAll(keys);
    },
    remoteRepo: remoteRepo,
    remoteTokenRepo: remoteTokenRepo,
    uid: uid,
    attrsDirtyStore: attrsDirtyStore,
    resetPendingStore: resetPendingStore,
    now: now,
  );
}

/// Fake server token store — tracks resetVault's tombstone + retry (finding 1).
class FakeRemoteTokenRepository implements RemoteTokenRepository {
  int tombstoneCount = 0;
  SyncError? tombstoneError;
  int tombstoneBeforeCount = 0;
  String? lastTombstoneBefore;
  SyncError? tombstoneBeforeError;

  @override
  Future<void> tombstoneAllRemote(String uid) async {
    if (tombstoneError != null) throw tombstoneError!;
    tombstoneCount++;
  }

  @override
  Future<void> tombstoneAllRemoteBefore(String uid, String beforeIso) async {
    if (tombstoneBeforeError != null) throw tombstoneBeforeError!;
    tombstoneBeforeCount++;
    lastTombstoneBefore = beforeIso;
  }

  @override
  Future<RemotePullResult> pullSince(String uid, String? sinceIso) async =>
      const RemotePullResult(rows: []);
  @override
  Future<void> pushUpsert(String uid, List<RawTokenRecord> records) async {}
  @override
  RealtimeChannelHandle subscribe(String uid, void Function() onChange) =>
      throw UnimplementedError();
}

/// Faz 3 Patch 2 — sahte sunucu key_attributes deposu.
class FakeKeyAttributesRepository implements KeyAttributesRepository {
  /// fetch() döneceği değer (null = gerçek 0-row → setup).
  KeyAttributes? remote;

  /// fetch/existsRemote bu hatayı fırlatır (ağ/RLS senaryosu).
  SyncError? fetchError;

  /// fetch'i askıya almak için (fetch-pending iken state=restoring testi).
  Future<void>? fetchGate;

  /// existsRemote() sonucu (upload guard).
  bool exists = false;

  int uploadCount = 0;
  KeyAttributes? uploaded;

  /// Faz 3 Patch 3 (Adım K) — update çağrı sayısı + son yazılan (changePassword sync).
  int updateCount = 0;
  KeyAttributes? updated;

  /// upload/update bu hatayı fırlatır (ağ hatası → dirty marker testi).
  SyncError? writeError;

  @override
  Future<KeyAttributes?> fetch(String uid) async {
    if (fetchGate != null) await fetchGate;
    if (fetchError != null) throw fetchError!;
    return remote;
  }

  @override
  Future<bool> existsRemote(String uid) async {
    if (fetchError != null) throw fetchError!;
    return exists;
  }

  @override
  Future<void> upload(String uid, KeyAttributes attrs) async {
    if (writeError != null) throw writeError!;
    uploadCount++;
    uploaded = attrs;
  }

  @override
  Future<void> update(String uid, KeyAttributes attrs) async {
    if (writeError != null) throw writeError!;
    updateCount++;
    updated = attrs;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSecureStorage storage;
  late KeyAttributesStore store;

  setUp(() {
    storage = FakeSecureStorage();
    store = KeyAttributesStore(storage: storage);
  });

  group('bootstrap', () {
    test('attrs yok → uninitialized', () async {
      final cubit = _build(FakeKeyManager(), store);
      await cubit.bootstrap();
      expect(cubit.state.status, VaultLockStatus.uninitialized);
    });

    test('attrs var → locked', () async {
      await store.write(_fakeAttrs());
      final cubit = _build(FakeKeyManager(), store);
      await cubit.bootstrap();
      expect(cubit.state.status, VaultLockStatus.locked);
    });

    test('attrs malformed → keyAttributesCorrupted', () async {
      storage.data[KeyAttributesStore.storageKey] = '{bozuk json';
      final cubit = _build(FakeKeyManager(), store);
      await cubit.bootstrap();
      expect(cubit.state.status, VaultLockStatus.keyAttributesCorrupted);
    });

    test('attrs okuması PlatformException atarsa → keyAttributesCorrupted '
        '(ASLA sessiz uninitialized — P1-2)', () async {
      // `resetOnError: false` (locator.dart) ile Keystore unwrap hatası artık
      // silme + null yerine bu istisnayı üretir. Yakalanmazsa bootstrap
      // future'ından kabarır ve kullanıcı SETUP ekranı görürdü.
      storage.readError = PlatformException(code: 'Keystore', message: 'test');
      final cubit = _build(FakeKeyManager(), store);
      await cubit.bootstrap();
      expect(cubit.state.status, VaultLockStatus.keyAttributesCorrupted);
      expect(cubit.state.status, isNot(VaultLockStatus.uninitialized));
    });

    test('retryBootstrap: platform hatası geçince locked\'a döner', () async {
      await store.write(_fakeAttrs());
      storage.readError = PlatformException(code: 'Keystore', message: 'test');
      final cubit = _build(FakeKeyManager(), store);
      await cubit.bootstrap();
      expect(cubit.state.status, VaultLockStatus.keyAttributesCorrupted);
      storage.readError = null; // geçici hataydı
      await cubit.retryBootstrap();
      expect(cubit.state.status, VaultLockStatus.locked);
    });
  });

  group('setup commit (recovery doğrulanmadan persist YOK)', () {
    test('beginSetup → setupPending, diske attrs YAZILMAZ', () async {
      final cubit = _build(FakeKeyManager(), store);
      await cubit.beginSetup('parola123');
      expect(cubit.state.status, VaultLockStatus.setupPending);
      expect(cubit.state.mnemonic.length, 24);
      expect(storage.data.containsKey(KeyAttributesStore.storageKey), isFalse);
    });

    test('commitSetup → attrs yazılır + migration + unlocked', () async {
      final migrated = <String>[];
      final cubit = _build(FakeKeyManager(), store, migrated: migrated);
      await cubit.beginSetup('parola123');
      await cubit.commitSetup();
      expect(cubit.state.status, VaultLockStatus.unlocked);
      expect(storage.data.containsKey(KeyAttributesStore.storageKey), isTrue);
      expect(migrated, ['migrated']); // migration commitSetup içinde çalıştı
    });

    test(
      'cancelSetup → masterKey dispose, uninitialized, persist YOK',
      () async {
        final km = FakeKeyManager();
        final cubit = _build(km, store);
        await cubit.beginSetup('parola123');
        cubit.cancelSetup();
        expect(cubit.state.status, VaultLockStatus.uninitialized);
        expect(km.issued.single.disposed, isTrue);
        expect(
          storage.data.containsKey(KeyAttributesStore.storageKey),
          isFalse,
        );
      },
    );

    test(
      'setup restart → önceki pending masterKey dispose edilir (review P2)',
      () async {
        final km = FakeKeyManager();
        final cubit = _build(km, store);
        await cubit.beginSetup('parola123'); // 1. pending key
        await cubit.beginSetup(
          'baska456',
        ); // restart → 1. key dispose, 2. üretilir
        expect(km.issued.length, 2);
        expect(km.issued[0].disposed, isTrue); // eski pending sızmadı
        expect(km.issued[1].disposed, isFalse); // yeni pending canlı
        expect(cubit.state.status, VaultLockStatus.setupPending);
      },
    );

    test(
      'beginSetup sürerken background → setupPending EMİT ETMEZ, üretilen key '
      'dispose, uninitialized, persist YOK (review P1)',
      () async {
        final gate = Completer<void>();
        final km = FakeKeyManager(setupGate: gate.future);
        final cubit = _build(km, store);

        final pending = cubit.beginSetup(
          'parola123',
        ); // setup'ta (Argon2id) asılı
        await Future<void>.delayed(Duration.zero);
        cubit.onAppBackgrounded(
          paused: true,
        ); // state uninitialized iken setup devam ediyor
        gate.complete();
        await pending;

        expect(
          cubit.state.status,
          VaultLockStatus.uninitialized,
        ); // setupPending DEĞİL
        expect(
          km.issued.single.disposed,
          isTrue,
        ); // masterKey + mnemonic sızmaz
        expect(() => cubit.masterKey, throwsStateError);
        expect(
          storage.data.containsKey(KeyAttributesStore.storageKey),
          isFalse,
        );
      },
    );

    test(
      'commitSetup migration fail → attrs diskte ama state ATOMİK: key dispose, '
      'pending temizlenir, locked (setupPending DEĞİL), rethrow (review P2)',
      () async {
        final km = FakeKeyManager();
        final cubit = _build(km, store, migrationFails: true);
        await cubit.beginSetup('parola123');

        await expectLater(cubit.commitSetup(), throwsStateError);
        // attrs YAZILDI (migration'dan önce) → vault var → locked tutarlı.
        expect(storage.data.containsKey(KeyAttributesStore.storageKey), isTrue);
        expect(
          cubit.state.status,
          VaultLockStatus.locked,
        ); // setupPending DEĞİL
        expect(km.issued.single.disposed, isTrue); // key sızmaz
        expect(() => cubit.masterKey, throwsStateError);
      },
    );

    test(
      'commitSetup attrs write FAIL → diske yazılmadı: key dispose, pending '
      'temizlenir, UNINITIALIZED (locked değil), rethrow (review P2 2.tur)',
      () async {
        final km = FakeKeyManager();
        final cubit = _build(km, store);
        await cubit.beginSetup('parola123');

        storage.failWrites = true; // _attrsStore.write fırlatacak
        await expectLater(cubit.commitSetup(), throwsA(isA<Exception>()));

        // write fail → attrs DİSKE YAZILMADI → vault kurulmadı → uninitialized.
        expect(
          storage.data.containsKey(KeyAttributesStore.storageKey),
          isFalse,
        );
        expect(
          cubit.state.status,
          VaultLockStatus.uninitialized,
        ); // locked DEĞİL
        expect(
          km.issued.single.disposed,
          isTrue,
        ); // masterKey arka planda sızmaz
        expect(() => cubit.masterKey, throwsStateError);
      },
    );

    test(
      'commitSetup write askıdayken BACKGROUND, sonra write FAIL → kesişim: '
      'key dispose, pending temizlenir, UNINITIALIZED, persist YOK (review P3 3.tur)',
      () async {
        // Önceki write-fail testi cleanup'ı doğruluyordu ama background çağrısı YOKTU;
        // background testi ise write BİTTİKTEN sonra _migrate'te bekletiyordu. Bu test
        // tam kesişimi kapatır: write _attrsStore.write()'ta ASILIYKEN app background
        // olur, SONRA write IO hatası verir. Beklenti: write-fail cleanup (uninitialized
        // + dispose) kazanır; _commitInFlight=true olduğu için onAppBackgrounded
        // cancelSetup ÇAĞIRMAZ (commit'in finalize etmesini bekler) — yani temizlik
        // tamamen write catch yoluyla yapılır, çift değil.
        final gate = Completer<void>();
        final km = FakeKeyManager();
        final cubit = _build(km, store);
        await cubit.beginSetup('parola123');

        storage.writeGate = gate.future; // write burada asılı kalacak
        storage.failWrites = true; // gate çözülünce throw edecek

        final commit = cubit.commitSetup(); // write'ta (askıda) bekliyor
        await Future<void>.delayed(Duration.zero);
        cubit.onAppBackgrounded(
          paused: true,
        ); // commit in-flight + setupPending iken background
        gate.complete(); // write throw eder
        await expectLater(commit, throwsA(isA<Exception>()));

        // write fail = diske yazılmadı → vault kurulmadı → uninitialized.
        expect(
          storage.data.containsKey(KeyAttributesStore.storageKey),
          isFalse,
        );
        expect(
          cubit.state.status,
          VaultLockStatus.uninitialized,
        ); // locked DEĞİL
        expect(
          km.issued.single.disposed,
          isTrue,
        ); // masterKey arka planda sızmaz
        expect(() => cubit.masterKey, throwsStateError);
      },
    );
  });

  group('unlock', () {
    test('doğru parola → unlocked + migration', () async {
      await store.write(_fakeAttrs());
      final migrated = <String>[];
      final cubit = _build(FakeKeyManager(), store, migrated: migrated);
      await cubit.bootstrap();
      await cubit.unlock('parola123');
      expect(cubit.state.status, VaultLockStatus.unlocked);
      expect(migrated, ['migrated']);
    });

    test('yanlış parola → locked + wrongPassword, masterKey yok', () async {
      await store.write(_fakeAttrs());
      final cubit = _build(FakeKeyManager(wrongPassword: true), store);
      await cubit.bootstrap();
      await cubit.unlock('yanlis');
      expect(cubit.state.status, VaultLockStatus.locked);
      expect(cubit.state.error, VaultLockError.wrongPassword);
    });

    test('migration fail → key dispose, unlocked DEĞİL (review P1)', () async {
      await store.write(_fakeAttrs());
      final km = FakeKeyManager();
      final cubit = _build(km, store, migrationFails: true);
      await cubit.bootstrap();
      // Migration fırlatır → exception caller'a kabarır; locked kalırız.
      await expectLater(cubit.unlock('parola123'), throwsStateError);
      expect(cubit.state.status, VaultLockStatus.locked); // unlocked'a GEÇMEZ
      expect(km.issued.single.disposed, isTrue); // masterKey sızmaz
      // Sahiplik geçmediği için masterKey getter erişimi de fırlatmalı.
      expect(() => cubit.masterKey, throwsStateError);
    });
  });

  group('recoverWithNewPassword (atomik)', () {
    test('başarılı → unlocked + yeni attrs persist + migration', () async {
      await store.write(_fakeAttrs());
      final migrated = <String>[];
      final cubit = _build(FakeKeyManager(), store, migrated: migrated);
      await cubit.bootstrap();
      await cubit.recoverWithNewPassword(
        List.generate(24, (i) => 'word$i'),
        'yeniParola1',
      );
      expect(cubit.state.status, VaultLockStatus.unlocked);
      expect(migrated, ['migrated']);
    });

    test('yanlış mnemonic → locked + wrongRecovery, ara key dispose', () async {
      await store.write(_fakeAttrs());
      final km = FakeKeyManager(wrongRecovery: true);
      final cubit = _build(km, store);
      await cubit.bootstrap();
      await cubit.recoverWithNewPassword(['a', 'b'], 'yeniParola1');
      expect(cubit.state.status, VaultLockStatus.locked);
      expect(cubit.state.error, VaultLockError.wrongRecovery);
      // recoverUnlock fırlattı → hiç key üretilmedi (issued boş).
      expect(km.issued, isEmpty);
    });

    test(
      'migration fail → ara key dispose, unlocked DEĞİL (review P1)',
      () async {
        await store.write(_fakeAttrs());
        final km = FakeKeyManager();
        final cubit = _build(km, store, migrationFails: true);
        await cubit.bootstrap();
        await expectLater(
          cubit.recoverWithNewPassword(
            List.generate(24, (i) => 'word$i'),
            'yeniParola1',
          ),
          throwsStateError,
        );
        expect(cubit.state.status, isNot(VaultLockStatus.unlocked));
        // recoverUnlock + changePassword key üretti; migration fail → dispose edilmeli.
        expect(km.issued.every((k) => k.disposed), isTrue);
        expect(() => cubit.masterKey, throwsStateError);
      },
    );
  });

  group('lifecycle lock (paused + inactive)', () {
    test('unlocked iken background → SENKRON dispose + locked (review P2: frame '
        'beklemez — paused\'ta frame garanti değil)', () async {
      await store.write(_fakeAttrs());
      final km = FakeKeyManager();
      final cubit = _build(km, store);
      await cubit.bootstrap();
      await cubit.unlock('parola123');

      cubit.onAppBackgrounded(paused: true);
      // Frame PUMP ETMEDEN: key zaten dispose + locked olmalı (key arka planda
      // canlı kalmaz — ARCHITECTURE §2.3).
      expect(cubit.state.status, VaultLockStatus.locked);
      expect(km.issued.single.disposed, isTrue);
    });

    test('interaktif lock() → locking, post-frame dispose → locked (yumuşak '
        'teardown korunur)', () async {
      await store.write(_fakeAttrs());
      final km = FakeKeyManager();
      final cubit = _build(km, store);
      await cubit.bootstrap();
      await cubit.unlock('parola123');

      cubit.lock(); // immediate: false → frame'li yol
      expect(cubit.state.status, VaultLockStatus.locking);
      expect(km.issued.single.disposed, isFalse); // repo use-after-free yok

      await _pumpFrame();
      expect(cubit.state.status, VaultLockStatus.locked);
      expect(km.issued.single.disposed, isTrue);
    });

    test('locking iken (frame GELMEDEN) background → SENKRON dispose + locked '
        '(post-frame\'e bel bağlamaz — review P1/P2)', () async {
      await store.write(_fakeAttrs());
      final km = FakeKeyManager();
      final cubit = _build(km, store);
      await cubit.bootstrap();
      await cubit.unlock('parola123');

      cubit
          .lock(); // locking; post-frame dispose KUYRUKTA ama frame pump ETMİYORUZ
      expect(cubit.state.status, VaultLockStatus.locking);
      expect(km.issued.single.disposed, isFalse);

      cubit.onAppBackgrounded(paused: true); // frame gelmeden background
      // Senkron dispose: key bellekte kalmaz, locked'a geçer.
      expect(cubit.state.status, VaultLockStatus.locked);
      expect(km.issued.single.disposed, isTrue);

      // Stale post-frame callback fire etse de no-op (status zaten locked).
      await _pumpFrame();
      expect(cubit.state.status, VaultLockStatus.locked);
    });

    test(
      'setupPending iken background → uninitialized, dispose, persist YOK',
      () async {
        final km = FakeKeyManager();
        final cubit = _build(km, store);
        await cubit.beginSetup('parola123');
        cubit.onAppBackgrounded(paused: true);
        expect(cubit.state.status, VaultLockStatus.uninitialized);
        expect(km.issued.single.disposed, isTrue);
        expect(
          storage.data.containsKey(KeyAttributesStore.storageKey),
          isFalse,
        );
      },
    );

    test('unlock sürerken background → işlem bitince UNLOCKED EMİT ETMEZ, key '
        'dispose, locked kalır (review P1 complete-after-background)', () async {
      await store.write(_fakeAttrs());
      final km = FakeKeyManager();
      final gate = Completer<void>();
      // Migration'ı askıya al: unlock _migrate'te beklerken background tetikle.
      final cubit = _build(km, store, migrateGate: gate.future);
      await cubit.bootstrap();

      final pending = cubit.unlock('parola123'); // _migrate'te asılı kalır
      await Future<void>.delayed(Duration.zero); // recoverUnlock/migrate'e gir
      cubit.onAppBackgrounded(
        paused: true,
      ); // state locked iken async işlem devam ediyor
      gate.complete(); // migration tamamlanır
      await pending;

      expect(cubit.state.status, VaultLockStatus.locked); // unlocked DEĞİL
      expect(km.issued.single.disposed, isTrue); // key sızmaz
      expect(() => cubit.masterKey, throwsStateError);
    });

    test(
      'recoverWithNewPassword sürerken background → unlocked EMİT ETMEZ, key '
      'dispose (review P1)',
      () async {
        await store.write(_fakeAttrs());
        final km = FakeKeyManager();
        final gate = Completer<void>();
        final cubit = _build(km, store, migrateGate: gate.future);
        await cubit.bootstrap();

        final pending = cubit.recoverWithNewPassword(
          List.generate(24, (i) => 'word$i'),
          'yeniParola1',
        );
        await Future<void>.delayed(Duration.zero);
        cubit.onAppBackgrounded(paused: true);
        gate.complete();
        await pending;

        expect(cubit.state.status, VaultLockStatus.locked);
        expect(km.issued.every((k) => k.disposed), isTrue);
        expect(() => cubit.masterKey, throwsStateError);
      },
    );

    test('commitSetup sürerken background → unlocked EMİT ETMEZ; attrs yazıldı '
        'için LOCKED (uninitialized değil), key dispose (review P1)', () async {
      final km = FakeKeyManager();
      final gate = Completer<void>();
      final cubit = _build(km, store, migrateGate: gate.future);
      await cubit.beginSetup('parola123');

      final pending = cubit.commitSetup(); // attrs write OK → _migrate'te asılı
      await Future<void>.delayed(Duration.zero);
      cubit.onAppBackgrounded(paused: true); // setupPending + commit in-flight
      gate.complete();
      await pending;

      // attrs diske yazıldı → vault var → locked (uninitialized değil).
      expect(cubit.state.status, VaultLockStatus.locked);
      expect(storage.data.containsKey(KeyAttributesStore.storageKey), isTrue);
      expect(km.issued.single.disposed, isTrue);
      expect(() => cubit.masterKey, throwsStateError);
    });
  });

  // Güvenlik denetimi P2-1 — plaintext tutucuları masterKey ile AYNI anda temizlenir.
  group('registerPlaintextHolder (P2-1)', () {
    Future<VaultLockCubit> unlocked(FakeKeyManager km) async {
      await store.write(_fakeAttrs());
      final cubit = _build(km, store);
      await cubit.bootstrap();
      await cubit.unlock('parola123');
      expect(cubit.state.status, VaultLockStatus.unlocked);
      return cubit;
    }

    test(
      'lock(immediate: true) tutucuyu ANAHTAR DISPOSE EDİLMEDEN ÖNCE çalıştırır',
      () async {
        final km = FakeKeyManager();
        final cubit = await unlocked(km);
        bool? keyAliveAtWipe;
        var calls = 0;
        cubit.registerPlaintextHolder(() {
          calls++;
          // Sıra kanıtı: temizlik çalışırken anahtar HÂLÂ canlı olmalı.
          keyAliveAtWipe = !km.issued.single.disposed;
        });

        cubit.lock(immediate: true); // arka plan yolu: frame BEKLENMEZ

        expect(calls, 1);
        expect(keyAliveAtWipe, isTrue);
        expect(km.issued.single.disposed, isTrue); // sonra anahtar gitti
        expect(cubit.state.status, VaultLockStatus.locked);
      },
    );

    test('arka plana geçiş (paused) tutucuyu çalıştırır', () async {
      final cubit = await unlocked(FakeKeyManager());
      var calls = 0;
      cubit.registerPlaintextHolder(() => calls++);
      cubit.onAppBackgrounded(paused: true);
      expect(calls, 1);
    });

    test('onAuthSignedOut tutucuyu çalıştırır', () async {
      final cubit = await unlocked(FakeKeyManager());
      var calls = 0;
      cubit.registerPlaintextHolder(() => calls++);
      cubit.onAuthSignedOut();
      expect(calls, 1);
    });

    test('resetVault tutucuyu çalıştırır', () async {
      final cubit = await unlocked(FakeKeyManager());
      var calls = 0;
      cubit.registerPlaintextHolder(() => calls++);
      await cubit.resetVault();
      expect(calls, greaterThanOrEqualTo(1));
    });

    test('close() tutucuyu çalıştırır', () async {
      final cubit = await unlocked(FakeKeyManager());
      var calls = 0;
      cubit.registerPlaintextHolder(() => calls++);
      await cubit.close();
      expect(calls, 1);
    });

    test('kayıt geri alınınca ARTIK çağrılmaz', () async {
      final cubit = await unlocked(FakeKeyManager());
      var calls = 0;
      final unregister = cubit.registerPlaintextHolder(() => calls++);
      unregister();
      cubit.lock(immediate: true);
      expect(calls, 0);
    });

    test(
      'bir tutucu FIRLATIRSA diğerleri + key dispose YİNE çalışır',
      () async {
        final km = FakeKeyManager();
        final cubit = await unlocked(km);
        var second = 0;
        cubit
          ..registerPlaintextHolder(() => throw StateError('tutucu patladı'))
          ..registerPlaintextHolder(() => second++);
        cubit.lock(immediate: true);
        expect(second, 1);
        expect(km.issued.single.disposed, isTrue);
        expect(cubit.state.status, VaultLockStatus.locked);
      },
    );
  });

  group('reset', () {
    test('resetVault → tüm anahtarlar silinir, biometric.disable çağrılır, '
        'uninitialized', () async {
      // Dolu storage simüle et.
      for (final k in VaultStorageKeys.all) {
        storage.data[k] = 'x';
      }
      final deleted = <String>[];
      final bio = FakeBiometricService();
      final cubit = _build(
        FakeKeyManager(),
        store,
        deletedSink: deleted,
        biometric: bio,
      );
      await cubit.resetVault();
      expect(cubit.state.status, VaultLockStatus.uninitialized);
      expect(deleted.toSet(), VaultStorageKeys.all.toSet());
      // Biyometrik anahtar ayrı storage'da → asıl temizlik disable() ile (reviewer P1).
      expect(bio.disableCount, 1);
      // Kırılgan length==N yerine biometric key dahil mi (reviewer 5.tur notu).
      expect(VaultStorageKeys.all, contains(VaultStorageKeys.biometricKey));
    });

    test(
      'unlocked iken reset ÖNCE lock(immediate) yolundan geçer (P3-2)',
      () async {
        await store.write(_fakeAttrs());
        final km = FakeKeyManager();
        final cubit = _build(km, store);
        await cubit.bootstrap();
        await cubit.unlock('parola123');
        expect(cubit.state.status, VaultLockStatus.unlocked);

        final seen = <VaultLockStatus>[];
        final sub = cubit.stream.listen((s) => seen.add(s.status));
        await cubit.resetVault();
        await Future<void>.delayed(Duration.zero); // stream teslimi
        await sub.cancel();

        // Durum makinesi ATLANMADI: locking → locked → uninitialized.
        expect(seen, [
          VaultLockStatus.locking,
          VaultLockStatus.locked,
          VaultLockStatus.uninitialized,
        ]);
        expect(km.issued.single.disposed, isTrue);
      },
    );

    test('signed-in reset tombstones the server token rows', () async {
      final tokenRepo = FakeRemoteTokenRepository();
      final cubit = _build(
        FakeKeyManager(),
        store,
        remoteRepo: FakeKeyAttributesRepository(),
        remoteTokenRepo: tokenRepo,
        uid: 'u1',
      );
      await cubit.resetVault();
      expect(cubit.state.status, VaultLockStatus.uninitialized);
      expect(tokenRepo.tombstoneCount, 1);
    });

    test(
      'offline tombstone → local reset completes + retry marker SET',
      () async {
        for (final k in VaultStorageKeys.all) {
          storage.data[k] = 'x';
        }
        final deleted = <String>[];
        final tokenRepo = FakeRemoteTokenRepository()
          ..tombstoneError = const SyncNetworkError();
        final resetStore = ResetPendingStore(storage: storage);
        final cubit = _build(
          FakeKeyManager(),
          store,
          deletedSink: deleted,
          remoteTokenRepo: tokenRepo,
          resetPendingStore: resetStore,
          uid: 'u1',
        );
        await cubit.resetVault();
        // Local reset is guaranteed even when the server can't be reached...
        expect(cubit.state.status, VaultLockStatus.uninitialized);
        expect(deleted.toSet(), VaultStorageKeys.all.toSet());
        // ...and a retry is owed (marker holds the reset instant).
        expect(await resetStore.pendingSince(), isNotNull);
      },
    );

    test('successful tombstone clears any prior retry marker', () async {
      final resetStore = ResetPendingStore(storage: storage);
      await resetStore.setPending('2026-01-01T00:00:00.000Z');
      final cubit = _build(
        FakeKeyManager(),
        store,
        remoteTokenRepo: FakeRemoteTokenRepository(),
        resetPendingStore: resetStore,
        uid: 'u1',
      );
      await cubit.resetVault();
      expect(await resetStore.pendingSince(), isNull);
    });

    test('legacy (uid == null) reset does not touch remote', () async {
      final tokenRepo = FakeRemoteTokenRepository();
      final cubit = _build(
        FakeKeyManager(),
        store,
        remoteTokenRepo: tokenRepo,
      ); // uid null
      await cubit.resetVault();
      expect(tokenRepo.tombstoneCount, 0);
    });

    test(
      'pending reset retried on next unlock — tombstones only pre-reset rows',
      () async {
        await store.write(_fakeAttrs());
        final resetStore = ResetPendingStore(storage: storage);
        await resetStore.setPending('2026-06-18T12:00:00.000Z');
        final tokenRepo = FakeRemoteTokenRepository();
        final cubit = _build(
          FakeKeyManager(),
          store,
          remoteTokenRepo: tokenRepo,
          resetPendingStore: resetStore,
          uid: 'u1',
        );
        await cubit.bootstrap();
        await cubit.unlock('parola123');
        await Future<void>.delayed(Duration.zero); // unawaited replay
        expect(tokenRepo.tombstoneBeforeCount, 1);
        expect(tokenRepo.lastTombstoneBefore, '2026-06-18T12:00:00.000Z');
        expect(await resetStore.pendingSince(), isNull); // cleared on success
      },
    );

    test('no pending marker → unlock does not call remote tombstone', () async {
      await store.write(_fakeAttrs());
      final tokenRepo = FakeRemoteTokenRepository();
      final cubit = _build(
        FakeKeyManager(),
        store,
        remoteTokenRepo: tokenRepo,
        resetPendingStore: ResetPendingStore(storage: storage),
        uid: 'u1',
      );
      await cubit.bootstrap();
      await cubit.unlock('parola123');
      await Future<void>.delayed(Duration.zero);
      expect(tokenRepo.tombstoneBeforeCount, 0);
    });
  });

  test('close → masterKey dispose', () async {
    await store.write(_fakeAttrs());
    final km = FakeKeyManager();
    final cubit = _build(km, store);
    await cubit.bootstrap();
    await cubit.unlock('parola123');
    await cubit.close();
    expect(km.issued.single.disposed, isTrue);
  });

  // --- Biyometri (Patch 5) ---

  group('biyometri bootstrap state', () {
    test(
      'bmk yok + cihaz available → enrolled false, deviceAvailable true',
      () async {
        await store.write(_fakeAttrs()); // bmk yok
        final cubit = _build(
          FakeKeyManager(),
          store,
          biometric: FakeBiometricService(available: true),
        );
        await cubit.bootstrap();
        expect(cubit.state.biometricEnrolled, isFalse);
        expect(cubit.state.deviceBiometricAvailable, isTrue);
        expect(cubit.state.biometricUnlockAvailable, isFalse);
      },
    );

    test(
      'bmk var + cihaz available → enrolled true, unlockAvailable true',
      () async {
        final bmk = EncryptedBlob(
          nonce: Uint8List(24),
          ciphertext: Uint8List(16),
        );
        await store.write(
          _fakeAttrs().copyWith(biometricEncryptedMasterKey: bmk),
        );
        final cubit = _build(
          FakeKeyManager(),
          store,
          biometric: FakeBiometricService(available: true),
        );
        await cubit.bootstrap();
        expect(cubit.state.biometricEnrolled, isTrue);
        expect(cubit.state.deviceBiometricAvailable, isTrue);
        expect(cubit.state.biometricUnlockAvailable, isTrue);
      },
    );

    test(
      'bmk var + cihaz unavailable → enrolled true ama unlockAvailable false',
      () async {
        final bmk = EncryptedBlob(
          nonce: Uint8List(24),
          ciphertext: Uint8List(16),
        );
        await store.write(
          _fakeAttrs().copyWith(biometricEncryptedMasterKey: bmk),
        );
        final cubit = _build(
          FakeKeyManager(),
          store,
          biometric: FakeBiometricService(available: false),
        );
        await cubit.bootstrap();
        expect(cubit.state.biometricEnrolled, isTrue);
        expect(cubit.state.deviceBiometricAvailable, isFalse);
        expect(cubit.state.biometricUnlockAvailable, isFalse);
      },
    );
  });

  group('unlock sonrası biyometri state korunur (reviewer 4.tur P1)', () {
    test(
      'parola unlock → unlocked state deviceBiometricAvailable taşır',
      () async {
        await store.write(_fakeAttrs());
        final cubit = _build(
          FakeKeyManager(),
          store,
          biometric: FakeBiometricService(available: true),
        );
        await cubit.bootstrap();
        await cubit.unlock('parola123');
        expect(cubit.state.status, VaultLockStatus.unlocked);
        expect(
          cubit.state.deviceBiometricAvailable,
          isTrue,
          reason: 'Settings switch enable edilebilmeli',
        );
        expect(cubit.state.biometricEnrolled, isFalse);
      },
    );

    test('commitSetup → unlocked deviceBiometricAvailable taşır', () async {
      final cubit = _build(
        FakeKeyManager(),
        store,
        biometric: FakeBiometricService(available: true),
      );
      await cubit.beginSetup('parola123');
      await cubit.commitSetup();
      expect(cubit.state.status, VaultLockStatus.unlocked);
      expect(cubit.state.deviceBiometricAvailable, isTrue);
      expect(cubit.state.biometricEnrolled, isFalse);
    });
  });

  group('enableBiometric / disableBiometric', () {
    Future<VaultLockCubit> unlocked(
      FakeBiometricService bio, {
      FakeKeyManager? km,
    }) async {
      await store.write(_fakeAttrs());
      final cubit = _build(km ?? FakeKeyManager(), store, biometric: bio);
      await cubit.bootstrap();
      await cubit.unlock('parola123');
      return cubit;
    }

    test('enableBiometric → enroll + attrs.write + state enrolled', () async {
      final bio = FakeBiometricService(available: true);
      final cubit = await unlocked(bio);
      await cubit.enableBiometric();
      expect(bio.enrollCount, 1);
      expect(cubit.state.status, VaultLockStatus.unlocked);
      expect(cubit.state.biometricEnrolled, isTrue);
      // attrs'a bmk yazıldı
      final persisted = await store.read();
      expect(persisted!.biometricEncryptedMasterKey, isNotNull);
    });

    test('enableBiometric: OS enroll OK + attrs.write FAIL → disable çağrılır, '
        'state değişmez (reviewer 2.tur P2)', () async {
      final bio = FakeBiometricService(available: true);
      final cubit = await unlocked(bio);
      storage.failWrites = true; // attrs.write patlasın (enroll'dan SONRA)
      await expectLater(cubit.enableBiometric(), throwsA(isA<Exception>()));
      expect(bio.enrollCount, 1);
      expect(bio.disableCount, 1, reason: 'orphan OS key temizlenmeli');
      expect(cubit.state.biometricEnrolled, isFalse, reason: 'state değişmedi');
    });

    test('enableBiometric: cihaz unavailable → BiometricUnavailable', () async {
      final bio = FakeBiometricService(available: false);
      final cubit = await unlocked(bio);
      await expectLater(
        cubit.enableBiometric(),
        throwsA(isA<BiometricUnavailable>()),
      );
      expect(bio.enrollCount, 0);
    });

    test('disableBiometric → disable + bmk temizlenir + state', () async {
      final bio = FakeBiometricService(available: true);
      final cubit = await unlocked(bio);
      await cubit.enableBiometric();
      await cubit.disableBiometric();
      expect(bio.disableCount, 1);
      expect(cubit.state.biometricEnrolled, isFalse);
      final persisted = await store.read();
      expect(persisted!.biometricEncryptedMasterKey, isNull);
    });
  });

  group('biometricUnlock', () {
    Future<VaultLockCubit> lockedEnrolled(
      FakeBiometricService bio, {
      FakeKeyManager? km,
    }) async {
      final bmk = EncryptedBlob(
        nonce: Uint8List(24),
        ciphertext: Uint8List(16),
      );
      await store.write(
        _fakeAttrs().copyWith(biometricEncryptedMasterKey: bmk),
      );
      final cubit = _build(km ?? FakeKeyManager(), store, biometric: bio);
      await cubit.bootstrap();
      return cubit;
    }

    test('başarı → unlocked + masterKey owned', () async {
      final km = FakeKeyManager();
      final cubit = await lockedEnrolled(FakeBiometricService(), km: km);
      await cubit.biometricUnlock();
      expect(cubit.state.status, VaultLockStatus.unlocked);
      expect(km.issued.single.disposed, isFalse); // owned
    });

    test('Canceled → sessiz locked, key owned değil', () async {
      final km = FakeKeyManager();
      final cubit = await lockedEnrolled(
        FakeBiometricService(retrieveError: const BiometricCanceled()),
        km: km,
      );
      await cubit.biometricUnlock();
      expect(cubit.state.status, VaultLockStatus.locked);
      expect(cubit.state.error, isNull);
      expect(km.issued, isEmpty); // biometricUnlock'a hiç ulaşmadı
    });

    test('Lockout → locked + biometricLockout', () async {
      final cubit = await lockedEnrolled(
        FakeBiometricService(retrieveError: const BiometricLockout()),
      );
      await cubit.biometricUnlock();
      expect(cubit.state.status, VaultLockStatus.locked);
      expect(cubit.state.error, VaultLockError.biometricLockout);
    });

    test(
      'KeyMissing → bmk PERSIST temizlenir + locked enrolled false',
      () async {
        final cubit = await lockedEnrolled(
          FakeBiometricService(retrieveError: const BiometricKeyMissing()),
        );
        await cubit.biometricUnlock();
        expect(cubit.state.status, VaultLockStatus.locked);
        expect(cubit.state.biometricEnrolled, isFalse);
        final persisted = await store.read();
        expect(
          persisted!.biometricEncryptedMasterKey,
          isNull,
          reason: 'döngü önleme: bmk persist temizlendi',
        );
      },
    );

    test('KeyMissing + attrs.write FAIL → locked deviceAvail false + '
        'biometricFailed (döngü yok)', () async {
      final cubit = await lockedEnrolled(
        FakeBiometricService(retrieveError: const BiometricKeyMissing()),
      );
      storage.failWrites = true; // clearBiometric write patlasın
      await cubit.biometricUnlock();
      expect(cubit.state.status, VaultLockStatus.locked);
      expect(cubit.state.deviceBiometricAvailable, isFalse);
      expect(cubit.state.error, VaultLockError.biometricFailed);
    });

    test('Unavailable → locked deviceBiometricAvailable false', () async {
      final cubit = await lockedEnrolled(
        FakeBiometricService(retrieveError: const BiometricUnavailable()),
      );
      await cubit.biometricUnlock();
      expect(cubit.state.status, VaultLockStatus.locked);
      expect(cubit.state.deviceBiometricAvailable, isFalse);
    });

    test('StorageError → locked + biometricFailed', () async {
      final cubit = await lockedEnrolled(
        FakeBiometricService(retrieveError: const BiometricStorageError()),
      );
      await cubit.biometricUnlock();
      expect(cubit.state.status, VaultLockStatus.locked);
      expect(cubit.state.error, VaultLockError.biometricFailed);
    });

    test('retrieve EŞLENMEMİŞ bir tip fırlatırsa prompt-in-flight bayrağı '
        'ASILI KALMAZ → sonraki inactive YİNE kilitler (P2-2)', () async {
      // `MissingPluginException` `PlatformException`'dan TÜREMEZ, dolayısıyla
      // `BiometricServiceImpl.retrieve`'in eşlemesine takılmaz ve domain
      // tiplerinden hiçbirine dönüşmeden yukarı çıkar. `UnlockPage` de
      // yakalamaz → eskiden bayrak sonsuza dek true kalır, `inactive` kilidi
      // cubit'in kalan ömrü boyunca devre dışı olurdu.
      final cubit = await lockedEnrolled(
        FakeBiometricService(
          retrieveError: MissingPluginException('kanal yok (test)'),
        ),
      );
      await expectLater(
        cubit.biometricUnlock(),
        throwsA(isA<MissingPluginException>()),
      );

      // Kullanıcı parolayla açar...
      await cubit.unlock('parola123');
      expect(cubit.state.status, VaultLockStatus.unlocked);

      // ...ve `inactive` (app switcher / bildirim gölgesi) YİNE kilitlemeli.
      cubit.onAppBackgrounded(paused: false);
      expect(cubit.state.status, VaultLockStatus.locked);
    });

    test('biometricUnlock unwrap fail → locked + biometricFailed', () async {
      final km = FakeKeyManager()..biometricUnwrapFails = true;
      final cubit = await lockedEnrolled(FakeBiometricService(), km: km);
      await cubit.biometricUnlock();
      expect(cubit.state.status, VaultLockStatus.locked);
      expect(cubit.state.error, VaultLockError.biometricFailed);
    });

    test(
      'retrieve askıdayken PAUSED → kesin abort: locked, key dispose',
      () async {
        final km = FakeKeyManager();
        final gate = Completer<void>();
        final cubit = await lockedEnrolled(
          FakeBiometricService(retrieveGate: gate.future),
          km: km,
        );
        final fut = cubit.biometricUnlock();
        await Future<void>.delayed(Duration.zero);
        cubit.onAppBackgrounded(paused: true); // gerçek arka plan
        gate.complete();
        await fut;
        expect(cubit.state.status, VaultLockStatus.locked);
        // key biometricUnlock'tan dönmüş olsa bile owned değil → dispose.
        for (final k in km.issued) {
          expect(k.disposed, isTrue);
        }
      },
    );

    test(
      'retrieve askıdayken INACTIVE (prompt-in-flight) → abort ETMEZ, unlocked '
      '(reviewer 2.tur P1)',
      () async {
        final km = FakeKeyManager();
        final gate = Completer<void>();
        final cubit = await lockedEnrolled(
          FakeBiometricService(retrieveGate: gate.future),
          km: km,
        );
        final fut = cubit.biometricUnlock();
        await Future<void>.delayed(Duration.zero);
        cubit.onAppBackgrounded(paused: false); // sistem prompt'unun inactive'i
        gate.complete();
        await fut;
        expect(
          cubit.state.status,
          VaultLockStatus.unlocked,
          reason: 'prompt-in-flight inactive abort etmemeli',
        );
        expect(km.issued.single.disposed, isFalse);
      },
    );
  });

  // --- Faz 5 Patch 1: sistem dosya seçici akışı kilit muafiyeti (plan §3.2) ---
  group('system file flow exemption', () {
    /// Testin kontrol ettiği saat — bütçe aşımı beklemeden simüle edilir.
    late DateTime clock;
    DateTime now() => clock;

    setUp(() => clock = DateTime.utc(2026, 9, 2, 10));

    Future<VaultLockCubit> unlockedCubit(FakeKeyManager km) async {
      await store.write(_fakeAttrs());
      final cubit = _build(km, store, now: now);
      await cubit.bootstrap();
      await cubit.unlock('parola123');
      expect(cubit.state.status, VaultLockStatus.unlocked);
      return cubit;
    }

    test(
      'beginSystemFileFlow sonrası PAUSED kilitlemez (picker arka plan üretir)',
      () async {
        final km = FakeKeyManager();
        final cubit = await unlockedCubit(km);

        cubit.beginSystemFileFlow();
        cubit.onAppBackgrounded(paused: true); // Android SAF picker'ın paused'ı

        expect(cubit.state.status, VaultLockStatus.unlocked);
        expect(km.issued.single.disposed, isFalse);
        expect(cubit.systemFileFlowActive, isTrue);
      },
    );

    test('endSystemFileFlow sonrası PAUSED yeniden kilitler', () async {
      final km = FakeKeyManager();
      final cubit = await unlockedCubit(km);

      cubit.beginSystemFileFlow();
      cubit.endSystemFileFlow();
      expect(cubit.systemFileFlowActive, isFalse);

      cubit.onAppBackgrounded(paused: true);
      expect(cubit.state.status, VaultLockStatus.locked);
      expect(km.issued.single.disposed, isTrue);
    });

    test('bütçe aşılınca muafiyet biter → PAUSED yine kilitler', () async {
      final km = FakeKeyManager();
      final cubit = await unlockedCubit(km);

      cubit.beginSystemFileFlow(budget: const Duration(minutes: 2));
      clock = clock.add(const Duration(minutes: 3)); // bütçe doldu

      expect(cubit.systemFileFlowActive, isFalse);
      expect(
        cubit.systemFileFlowExpired,
        isTrue,
        reason: 'resume\'da main.dart bunu görüp hemen kilitler',
      );

      cubit.onAppBackgrounded(paused: true);
      expect(cubit.state.status, VaultLockStatus.locked);
      expect(km.issued.single.disposed, isTrue);
    });

    test('begin → bütçe aşımı → end KİLİTLER (resume beklenmez)', () async {
      final km = FakeKeyManager();
      final cubit = await unlockedCubit(km);

      cubit.beginSystemFileFlow(budget: const Duration(minutes: 2));
      clock = clock.add(const Duration(minutes: 3)); // picker 3 dk açık kaldı
      cubit.endSystemFileFlow(); // picker sonucu `resumed`'dan ÖNCE gelebilir

      expect(
        cubit.state.status,
        VaultLockStatus.locked,
        reason:
            'bütçe aşımı end anında uygulanır — main.dart resume kontrolü '
            'yarışı kaybedebilir',
      );
      expect(km.issued.single.disposed, isTrue);
      expect(cubit.systemFileFlowActive, isFalse);
      expect(cubit.systemFileFlowExpired, isFalse, reason: 'bayrak temizlendi');
    });

    test(
      'begin → bütçe İÇİNDE end kilitlemez (normal import/export)',
      () async {
        final km = FakeKeyManager();
        final cubit = await unlockedCubit(km);

        cubit.beginSystemFileFlow(budget: const Duration(minutes: 2));
        clock = clock.add(const Duration(minutes: 1)); // bütçe içinde
        cubit.endSystemFileFlow();

        expect(cubit.state.status, VaultLockStatus.unlocked);
        expect(km.issued.single.disposed, isFalse);
        expect(cubit.systemFileFlowActive, isFalse);
      },
    );

    test('akış YOKKEN systemFileFlowExpired false (resume no-op)', () async {
      final km = FakeKeyManager();
      final cubit = await unlockedCubit(km);
      expect(cubit.systemFileFlowExpired, isFalse);
      expect(cubit.systemFileFlowActive, isFalse);
    });

    test(
      'muafiyet onAuthSignedOut\'u ETKİLEMEZ (kimlik kapısı kapandıysa kilit)',
      () async {
        final km = FakeKeyManager();
        final cubit = await unlockedCubit(km);

        cubit.beginSystemFileFlow();
        cubit.onAuthSignedOut();

        expect(cubit.state.status, VaultLockStatus.locked);
        expect(km.issued.single.disposed, isTrue);
      },
    );

    // --- Denetim C10: yenileme serbest, ama MUTLAK tavan var ---

    test(
      'yenileme bütçeyi uzatır (bulut klasörlerinde gezinen kullanıcı)',
      () async {
        final km = FakeKeyManager();
        final cubit = await unlockedCubit(km);

        cubit.beginSystemFileFlow(); // 2 dk
        clock = clock.add(const Duration(minutes: 1, seconds: 50));
        expect(cubit.systemFileFlowActive, isTrue);

        cubit.beginSystemFileFlow(); // yenile → +2 dk
        clock = clock.add(const Duration(minutes: 1));

        expect(
          cubit.systemFileFlowActive,
          isTrue,
          reason: 'yenileme olmasaydı bütçe dolmuştu',
        );
      },
    );

    test('10 dakikalık MUTLAK tavan aşılınca yenileme REDDEDİLİR', () async {
      final km = FakeKeyManager();
      final cubit = await unlockedCubit(km);

      // İlk begin'den itibaren 2 dakikada bir yenile: tavan gelene kadar sürer.
      cubit.beginSystemFileFlow();
      for (var i = 0; i < 4; i++) {
        clock = clock.add(const Duration(minutes: 2));
        cubit.beginSystemFileFlow();
        expect(
          cubit.systemFileFlowActive,
          isTrue,
          reason: 'tavana kadar (t=${(i + 1) * 2}dk) yenileme geçerli',
        );
      }
      // t = 8 dk, son yenileme t=10 dk'ya kadar geçerli.
      clock = clock.add(const Duration(minutes: 2)); // t = 10 dk → tavan
      cubit.beginSystemFileFlow(); // REDDEDİLİR (deadline uzatılmaz)

      expect(cubit.systemFileFlowActive, isFalse);
      expect(
        cubit.systemFileFlowExpired,
        isTrue,
        reason: 'main.dart resume kontrolü kilitleyebilsin',
      );

      // Ve arka plana düşen uygulama artık KİLİTLENİR.
      cubit.onAppBackgrounded(paused: true);
      expect(cubit.state.status, VaultLockStatus.locked);
      expect(km.issued.single.disposed, isTrue);
    });

    test(
      'tavan endSystemFileFlow ile SIFIRLANIR (sonraki akış tam bütçeli)',
      () async {
        final km = FakeKeyManager();
        final cubit = await unlockedCubit(km);

        cubit.beginSystemFileFlow();
        clock = clock.add(VaultLockCubit.systemFileFlowMaxTotal);
        cubit.endSystemFileFlow(); // bütçe dolmuştu → kilit uygulanır
        expect(cubit.state.status, VaultLockStatus.locked);

        await cubit.unlock('parola123');
        cubit.beginSystemFileFlow(); // yeni akış → yeni mutlak saat

        expect(cubit.systemFileFlowActive, isTrue);
      },
    );
  });

  // --- Faz 3 Patch 1: onAuthSignedOut (kimlik kapısı kapanınca volatile temizlik) ---
  group('onAuthSignedOut', () {
    test('unlocked → locked + masterKey dispose', () async {
      await store.write(_fakeAttrs());
      final km = FakeKeyManager();
      final cubit = _build(km, store);
      await cubit.bootstrap();
      await cubit.unlock('parola123');
      expect(cubit.state.status, VaultLockStatus.unlocked);

      cubit.onAuthSignedOut(); // immediate lock
      expect(cubit.state.status, VaultLockStatus.locked);
      expect(km.issued.single.disposed, isTrue);
    });

    test(
      'setupPending (commit YOK) → cancelSetup → uninitialized (key+mnemonic temiz)',
      () async {
        final km = FakeKeyManager();
        final cubit = _build(km, store);
        await cubit.bootstrap();
        await cubit.beginSetup('parola123');
        expect(cubit.state.status, VaultLockStatus.setupPending);

        cubit.onAuthSignedOut();
        expect(cubit.state.status, VaultLockStatus.uninitialized);
        expect(km.issued.single.disposed, isTrue); // mnemonic+key temizlendi
      },
    );

    test(
      'setupPending + commit-in-flight → cancelSetup ÇAĞRILMAZ + abort; commit '
      'bitince unlocked EMİT EDİLMEZ (reviewer [P3] :400 kuralı)',
      () async {
        final km = FakeKeyManager();
        final gate = Completer<void>();
        storage.writeGate =
            gate.future; // commitSetup attrs.write'da asılı kalır
        final cubit = _build(km, store);
        await cubit.bootstrap();
        await cubit.beginSetup('parola123');

        final commit = cubit
            .commitSetup(); // _commitInFlight = true, write askıda
        // signOut commit sürerken: cancelSetup ÇAĞRILMAMALI (no-op gibi), abort set.
        cubit.onAuthSignedOut();
        expect(
          cubit.state.status,
          VaultLockStatus.setupPending,
          reason: 'commit sürerken cancelSetup çağrılmaz',
        );

        gate.complete(); // write tamamlanır → commit devam eder
        await commit;
        // abort nedeniyle unlocked EMİT EDİLMEZ; attrs yazıldıysa locked.
        expect(cubit.state.status, isNot(VaultLockStatus.unlocked));
        expect(cubit.state.status, VaultLockStatus.locked);
      },
    );

    test('locking → senkron dispose + locked', () async {
      await store.write(_fakeAttrs());
      final km = FakeKeyManager();
      final cubit = _build(km, store);
      await cubit.bootstrap();
      await cubit.unlock('parola123');
      cubit.lock(); // interaktif → locking (post-frame dispose kuyrukta)
      expect(cubit.state.status, VaultLockStatus.locking);

      cubit.onAuthSignedOut(); // locking'de senkron dispose + locked
      expect(cubit.state.status, VaultLockStatus.locked);
      expect(km.issued.single.disposed, isTrue);
    });

    test('locked + devam eden unlock → abort (unlocked\'a geçmez)', () async {
      await store.write(_fakeAttrs());
      final km = FakeKeyManager();
      final migrateGate = Completer<void>();
      final cubit = _build(km, store, migrateGate: migrateGate.future);
      await cubit.bootstrap();

      final unlocking = cubit.unlock('parola123'); // migration'da asılı
      cubit.onAuthSignedOut(); // _abortToBackground = true
      migrateGate.complete();
      await unlocking;
      expect(
        cubit.state.status,
        isNot(VaultLockStatus.unlocked),
        reason: 'abort sonrası unlocked emit edilmemeli',
      );
      expect(km.issued.single.disposed, isTrue);
    });
  });

  // --- Faz 3 Patch 2: restore (yeni cihaz) + backfill (upload) ---
  group('Patch 2 — bootstrap restore', () {
    test(
      'lokal attrs VAR → fetch ATLANIR + locked (Patch 1 korunur)',
      () async {
        await store.write(_fakeAttrs()); // lokal var
        final repo = FakeKeyAttributesRepository()..remote = _fakeAttrs();
        final cubit = _build(
          FakeKeyManager(),
          store,
          remoteRepo: repo,
          uid: 'uid-A',
        );
        await cubit.bootstrap();
        expect(cubit.state.status, VaultLockStatus.locked);
        expect(repo.uploadCount, 0); // backfill bootstrap'ta değil unlocked'ta
        await cubit.close();
      },
    );

    test(
      'remoteRepo=null → eski davranış (uninitialized, regresyon)',
      () async {
        final cubit = _build(FakeKeyManager(), store); // remoteRepo yok
        await cubit.bootstrap();
        expect(cubit.state.status, VaultLockStatus.uninitialized);
        await cubit.close();
      },
    );

    test('uid=null → restore yok (uninitialized)', () async {
      final repo = FakeKeyAttributesRepository()..remote = _fakeAttrs();
      final cubit = _build(
        FakeKeyManager(),
        store,
        remoteRepo: repo,
      ); // uid yok
      await cubit.bootstrap();
      expect(cubit.state.status, VaultLockStatus.uninitialized);
      await cubit.close();
    });

    test('remote VAR → lokale yazılır + locked (yeni cihaz restore)', () async {
      final repo = FakeKeyAttributesRepository()..remote = _fakeAttrs();
      final cubit = _build(
        FakeKeyManager(),
        store,
        remoteRepo: repo,
        uid: 'uid-A',
      );
      await cubit.bootstrap();
      expect(cubit.state.status, VaultLockStatus.locked);
      // server-wins: lokale yazıldı (sonraki bootstrap fetch atlar).
      expect(await store.read(), isNotNull);
      await cubit.close();
    });

    test('remote 0-row (gerçek yeni hesap) → uninitialized (setup)', () async {
      final repo = FakeKeyAttributesRepository()..remote = null; // 0-row
      final cubit = _build(
        FakeKeyManager(),
        store,
        remoteRepo: repo,
        uid: 'uid-A',
      );
      await cubit.bootstrap();
      expect(cubit.state.status, VaultLockStatus.uninitialized);
      await cubit.close();
    });

    test(
      'remote AĞ HATASI → restoreFailed (setup\'a DÜŞMEZ — kritik)',
      () async {
        final repo = FakeKeyAttributesRepository()
          ..fetchError = const SyncNetworkError();
        final cubit = _build(
          FakeKeyManager(),
          store,
          remoteRepo: repo,
          uid: 'uid-A',
        );
        await cubit.bootstrap();
        expect(cubit.state.status, VaultLockStatus.restoreFailed);
        expect(
          cubit.state.status,
          isNot(VaultLockStatus.uninitialized),
        ); // çift-vault yok
        await cubit.close();
      },
    );

    test(
      'remote VAR ama LOKAL write IO hatası → restoreFailed (restoring\'te ASILMAZ, '
      'setup DEĞİL, unhandled future YOK — reviewer [P2])',
      () async {
        final repo = FakeKeyAttributesRepository()..remote = _fakeAttrs();
        storage.failWrites =
            true; // _attrsStore.write Keychain/Keystore IO hatası
        final cubit = _build(
          FakeKeyManager(),
          store,
          remoteRepo: repo,
          uid: 'uid-A',
        );
        await cubit.bootstrap(); // kabaran hata YOK (catch (_) yakalar)
        expect(cubit.state.status, VaultLockStatus.restoreFailed);
        expect(
          cubit.state.status,
          isNot(VaultLockStatus.restoring),
        ); // asılı kalmaz
        expect(
          cubit.state.status,
          isNot(VaultLockStatus.uninitialized),
        ); // setup'a düşmez
        await cubit.close();
      },
    );

    test(
      'fetch PENDING iken state=restoring (asla uninitialized/setup — review [P1] #1)',
      () async {
        final gate = Completer<void>();
        final repo = FakeKeyAttributesRepository()
          ..remote = _fakeAttrs()
          ..fetchGate = gate.future;
        final cubit = _build(
          FakeKeyManager(),
          store,
          remoteRepo: repo,
          uid: 'uid-A',
        );
        final booting = cubit.bootstrap(); // fetch'te asılı
        await Future<void>.delayed(Duration.zero);
        expect(
          cubit.state.status,
          VaultLockStatus.restoring,
          reason: 'fetch sürerken /setup görünmemeli',
        );
        gate.complete();
        await booting;
        expect(cubit.state.status, VaultLockStatus.locked);
        await cubit.close();
      },
    );

    test(
      'retryRestore: restoreFailed → tekrar dener → başarı locked',
      () async {
        final repo = FakeKeyAttributesRepository()
          ..fetchError = const SyncNetworkError();
        final cubit = _build(
          FakeKeyManager(),
          store,
          remoteRepo: repo,
          uid: 'uid-A',
        );
        await cubit.bootstrap();
        expect(cubit.state.status, VaultLockStatus.restoreFailed);
        // ağ geldi: hata temizle + remote dolu.
        repo
          ..fetchError = null
          ..remote = _fakeAttrs();
        await cubit.retryRestore();
        expect(cubit.state.status, VaultLockStatus.locked);
        await cubit.close();
      },
    );

    test(
      'retryRestore yalnız restoreFailed\'da çalışır (başka state no-op)',
      () async {
        final repo = FakeKeyAttributesRepository()..remote = _fakeAttrs();
        final cubit = _build(
          FakeKeyManager(),
          store,
          remoteRepo: repo,
          uid: 'uid-A',
        );
        await cubit.bootstrap(); // locked
        await cubit.retryRestore(); // no-op
        expect(cubit.state.status, VaultLockStatus.locked);
        await cubit.close();
      },
    );
  });

  group('Patch 2 — backfill (upload guard)', () {
    test('unlock başarı + sunucuda YOK → insert (backfill)', () async {
      await store.write(_fakeAttrs());
      final repo = FakeKeyAttributesRepository()..exists = false;
      final cubit = _build(
        FakeKeyManager(),
        store,
        remoteRepo: repo,
        uid: 'uid-A',
      );
      await cubit.bootstrap(); // locked (lokal var)
      await cubit.unlock('parola123');
      await Future<void>.delayed(Duration.zero); // unawaited backfill
      expect(cubit.state.status, VaultLockStatus.unlocked);
      expect(repo.uploadCount, 1);
      await cubit.close();
    });

    test(
      'unlock başarı + sunucuda VAR → upload ÇAĞRILMAZ (server-wins guard)',
      () async {
        await store.write(_fakeAttrs());
        final repo = FakeKeyAttributesRepository()..exists = true;
        final cubit = _build(
          FakeKeyManager(),
          store,
          remoteRepo: repo,
          uid: 'uid-A',
        );
        await cubit.bootstrap();
        await cubit.unlock('parola123');
        await Future<void>.delayed(Duration.zero);
        expect(repo.uploadCount, 0);
        await cubit.close();
      },
    );

    test(
      'backfill ağ hatası unlocked\'ı BOZMAZ (best-effort sessiz)',
      () async {
        await store.write(_fakeAttrs());
        final repo = FakeKeyAttributesRepository()
          ..fetchError = const SyncNetworkError(); // existsRemote throw
        final cubit = _build(
          FakeKeyManager(),
          store,
          remoteRepo: repo,
          uid: 'uid-A',
        );
        await cubit.bootstrap();
        await cubit.unlock('parola123');
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.status, VaultLockStatus.unlocked); // hata yutuldu
        await cubit.close();
      },
    );

    test('remoteRepo=null → backfill no-op (regresyon)', () async {
      await store.write(_fakeAttrs());
      final cubit = _build(FakeKeyManager(), store); // remoteRepo yok
      await cubit.bootstrap();
      await cubit.unlock('parola123');
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.status, VaultLockStatus.unlocked);
      await cubit.close();
    });
  });

  group('Patch 3 (Adım K) — key_attributes UPDATE senkronu + dirty retry', () {
    test(
      'recoverWithNewPassword + sunucuda VAR → update çağrılır (insert DEĞİL)',
      () async {
        await store.write(_fakeAttrs());
        final repo = FakeKeyAttributesRepository()..exists = true;
        final dirty = AttrsDirtyStore(storage: storage);
        final cubit = _build(
          FakeKeyManager(),
          store,
          remoteRepo: repo,
          uid: 'uA',
          attrsDirtyStore: dirty,
        );
        await cubit.bootstrap();
        await cubit.recoverWithNewPassword(
          List.generate(24, (i) => 'word$i'),
          'yeniParola1',
        );
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.status, VaultLockStatus.unlocked);
        expect(repo.updateCount, 1, reason: 'var olan satır UPDATE edildi');
        expect(repo.uploadCount, 0, reason: 'insert DEĞİL');
        expect(
          await dirty.isDirty(),
          isFalse,
          reason: 'başarı → marker temizlendi',
        );
        await cubit.close();
      },
    );

    test(
      'recoverWithNewPassword + sunucuda YOK → upload (ilk insert)',
      () async {
        await store.write(_fakeAttrs());
        final repo = FakeKeyAttributesRepository()..exists = false;
        final dirty = AttrsDirtyStore(storage: storage);
        final cubit = _build(
          FakeKeyManager(),
          store,
          remoteRepo: repo,
          uid: 'uA',
          attrsDirtyStore: dirty,
        );
        await cubit.bootstrap();
        await cubit.recoverWithNewPassword(
          List.generate(24, (i) => 'word$i'),
          'yeniParola1',
        );
        await Future<void>.delayed(Duration.zero);
        expect(repo.uploadCount, 1);
        expect(repo.updateCount, 0);
        expect(await dirty.isDirty(), isFalse);
        await cubit.close();
      },
    );

    test(
      'update ağ hatası → dirty marker SET kalır (unlocked\'ı bozmaz)',
      () async {
        await store.write(_fakeAttrs());
        final repo = FakeKeyAttributesRepository()
          ..exists = true
          ..writeError = const SyncNetworkError();
        final dirty = AttrsDirtyStore(storage: storage);
        final cubit = _build(
          FakeKeyManager(),
          store,
          remoteRepo: repo,
          uid: 'uA',
          attrsDirtyStore: dirty,
        );
        await cubit.bootstrap();
        await cubit.recoverWithNewPassword(
          List.generate(24, (i) => 'word$i'),
          'yeniParola1',
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          cubit.state.status,
          VaultLockStatus.unlocked,
          reason: 'best-effort: ağ hatası unlocked\'ı bozmaz',
        );
        expect(await dirty.isDirty(), isTrue, reason: 'retry için SET kalır');
        await cubit.close();
      },
    );

    test(
      'dirty-replay: sonraki unlock + ağ var → update + marker CLEAR',
      () async {
        await store.write(_fakeAttrs());
        // Marker'ı önceden SET et (önceki turda changePassword ağ hatasına düşmüş gibi).
        final dirty = AttrsDirtyStore(storage: storage);
        await dirty.setDirty();
        final repo = FakeKeyAttributesRepository()..exists = true;
        final cubit = _build(
          FakeKeyManager(),
          store,
          remoteRepo: repo,
          uid: 'uA',
          attrsDirtyStore: dirty,
        );
        await cubit.bootstrap();
        await cubit.unlock('parola123');
        await Future<void>.delayed(Duration.zero);
        expect(repo.updateCount, 1, reason: 'unlock dirty-replay → update');
        expect(await dirty.isDirty(), isFalse, reason: 'başarı → temizlendi');
        await cubit.close();
      },
    );

    test('uid=null → changePassword sync no-op (legacy regresyon)', () async {
      await store.write(_fakeAttrs());
      final dirty = AttrsDirtyStore(storage: storage);
      final cubit = _build(
        FakeKeyManager(),
        store,
        attrsDirtyStore: dirty,
      ); // remoteRepo/uid yok
      await cubit.bootstrap();
      await cubit.recoverWithNewPassword(
        List.generate(24, (i) => 'word$i'),
        'yeniParola1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.status, VaultLockStatus.unlocked);
      // marker setDirty edildi ama replay no-op (repo yok) → SET kalır, zararsız.
      await cubit.close();
    });
  });
}

/// `addPostFrameCallback` ile kuyruğa alınan callback'leri fire ettirir
/// (lock()/onAppBackgrounded'ın post-frame dispose'unu test etmek için).
Future<void> _pumpFrame() async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.scheduleFrame();
  binding.handleBeginFrame(Duration.zero);
  binding.handleDrawFrame();
  await Future<void>.delayed(Duration.zero);
}
