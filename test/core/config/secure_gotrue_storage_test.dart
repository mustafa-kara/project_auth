/// `SecureLocalStorage` / `SecureGotrueAsyncStorage` testleri (review [P2-5]).
///
/// Kapsanan:
///  * `LocalStorage` sözleşmesinin varsayılanla AYNI anlambilimi (has/read/
///    persist/remove) — ama Keychain/Keystore'da.
///  * **Göç**: mevcut kullanıcılar güncellemede ÇIKIŞ YAPMAMALI. Eski kayıt
///    gerçek `SharedPreferences.setMockInitialValues` ile kurulur → hem prefs
///    anahtar adı hem `SharedPreferencesLocalStorage` yolu uçtan uca pinlenir.
///  * Keystore/Keychain reddi (PlatformException) açılışı BLOKLAMAZ; "oturum
///    yok" olarak yorumlanır (vault verisinden kasıtlı farklı — dosya başlığı).
///
/// Kapsanmayan: `Supabase.initialize`'ın bu nesneleri gerçekten kullanması
/// (main.dart derleme zamanı bağı; gotrue'nun kendi testleri sözleşmeyi tutar).
library;

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/config/secure_gotrue_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Bellek içi sahte — `test/features/auth/key_attributes_store_test.dart`
/// ile aynı kalıp (`implements` + `noSuchMethod`).
class FakeSecureStorage implements FlutterSecureStorage {
  FakeSecureStorage({this.failWith, this.failContainsKeyWith});

  final Map<String, String> data = {};

  /// Doluysa her çağrı bununla patlar (Keystore/Keychain reddi taklidi).
  final PlatformException? failWith;

  /// Doluysa YALNIZ `containsKey` patlar — göç "bilinmeyen ≠ yok" davranışını
  /// ölçmek için okuma/yazma çalışır durumda kalmalı (doğrulama NEW-6).
  final PlatformException? failContainsKeyWith;

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
    if (failWith != null) throw failWith!;
    return data[key];
  }

  @override
  Future<bool> containsKey({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async {
    if (failContainsKeyWith != null) throw failContainsKeyWith!;
    if (failWith != null) throw failWith!;
    return data.containsKey(key);
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
    if (failWith != null) throw failWith!;
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
    if (failWith != null) throw failWith!;
    data.remove(key);
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // `Supabase.initialize`'ın ürettiği anahtarın AYNISI olmalı; yoksa göç eski
  // kaydı bulamaz (supabase_flutter/lib/src/supabase.dart:132).
  const key = 'sb-abcdefgh-auth-token';
  const session = '{"refresh_token":"rt-123","access_token":"at-456"}';

  group('supabasePersistSessionKeyFor', () {
    test('supabase_flutter varsayılanıyla birebir aynı biçim', () {
      expect(
        supabasePersistSessionKeyFor('https://abcdefgh.supabase.co'),
        'sb-abcdefgh-auth-token',
      );
    });
  });

  group('secureStorageOptions', () {
    test('Android otomatik silmeyi KAPATIR (review [P1-2])', () {
      final map = secureStorageOptions().android.toMap();
      expect(map['resetOnError'], 'false');
      expect(map['migrateWithBackup'], 'true');
    });

    test('iOS ögesi cihazdan ÇIKMAZ (review [P3-1])', () {
      expect(
        secureStorageOptions().ios.toMap()['accessibility'],
        'unlocked_this_device',
      );
    });
  });

  group('SecureLocalStorage', () {
    late FakeSecureStorage storage;

    setUp(() {
      storage = FakeSecureStorage();
      SharedPreferences.setMockInitialValues({});
    });

    SecureLocalStorage build({FlutterSecureStorage? override}) =>
        SecureLocalStorage(
          persistSessionKey: key,
          storage: override ?? storage,
        );

    test(
      'persist → has/accessToken → remove (varsayılan anlambilim)',
      () async {
        final sut = build();
        await sut.initialize();

        expect(await sut.hasAccessToken(), isFalse);
        expect(await sut.accessToken(), isNull);

        await sut.persistSession(session);
        expect(await sut.hasAccessToken(), isTrue);
        // Adına rağmen TÜM serileşmiş oturum döner (yalnız access token değil).
        expect(await sut.accessToken(), session);
        expect(storage.data[key], session);

        await sut.removePersistedSession();
        expect(await sut.hasAccessToken(), isFalse);
        expect(storage.data, isEmpty);
      },
    );

    test('oturum SharedPreferences\'a YAZILMAZ', () async {
      final sut = build();
      await sut.initialize();
      await sut.persistSession(session);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(key),
        isNull,
        reason: 'refresh token düz prefs dosyasına sızmamalı',
      );
    });

    group('göç', () {
      test(
        'eski prefs oturumu secure storage\'a TAŞINIR ve prefs silinir',
        () async {
          SharedPreferences.setMockInitialValues({key: session});

          final sut = build();
          await sut.initialize();

          expect(
            storage.data[key],
            session,
            reason: 'mevcut kullanıcı güncellemede çıkış YAPMAMALI',
          );
          final prefs = await SharedPreferences.getInstance();
          expect(
            prefs.getString(key),
            isNull,
            reason: 'düz metin kopya geride BIRAKILMAMALI',
          );
          expect(await sut.accessToken(), session);
        },
      );

      test('secure storage doluysa bayat prefs değeri onu EZMEZ', () async {
        const fresh = '{"refresh_token":"rt-fresh"}';
        storage.data[key] = fresh;
        SharedPreferences.setMockInitialValues({
          key: '{"refresh_token":"rt-old"}',
        });

        final sut = build();
        await sut.initialize();

        expect(storage.data[key], fresh);
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString(key),
          isNull,
          reason: 'eski kopya yine de temizlenir',
        );
      });

      test('göçecek bir şey yoksa no-op', () async {
        final sut = build();
        await sut.initialize();
        expect(storage.data, isEmpty);
      });

      test(
        'containsKey patlarsa göç İPTAL: canlı secure oturum EZİLMEZ (NEW-6)',
        () async {
          // "Bilinmeyen"i "yok" saymak, bayat prefs oturumunun canlı olanın
          // üzerine yazılması demekti (bozuk refresh token → gereksiz çıkış).
          const fresh = '{"refresh_token":"rt-fresh"}';
          const staleValue = '{"refresh_token":"rt-old"}';
          final flaky = FakeSecureStorage(
            failContainsKeyWith: PlatformException(code: 'keystore'),
          );
          flaky.data[key] = fresh;
          SharedPreferences.setMockInitialValues({key: staleValue});

          final sut = build(override: flaky);
          await sut.initialize(); // patlamamalı

          expect(
            flaky.data[key],
            fresh,
            reason: 'canlı oturum bayat kopyayla EZİLMEMELİ',
          );
          final prefs = await SharedPreferences.getInstance();
          expect(
            prefs.getString(key),
            staleValue,
            reason: 'göç yapılmadıysa prefs kopyası da SİLİNMEZ (retry)',
          );
        },
      );

      test(
        'secure yazma reddedilirse prefs kaydı SİLİNMEZ (göç yeniden denenir)',
        () async {
          SharedPreferences.setMockInitialValues({key: session});
          final broken = FakeSecureStorage(
            failWith: PlatformException(code: 'keystore'),
          );

          final sut = build(override: broken);
          await sut.initialize(); // patlamamalı

          final prefs = await SharedPreferences.getInstance();
          expect(
            prefs.getString(key),
            session,
            reason: 'yazma başarısızken silersek oturum tamamen kaybolurdu',
          );
        },
      );
    });

    group('Keystore/Keychain reddi', () {
      late SecureLocalStorage sut;
      setUp(() {
        sut = build(
          override: FakeSecureStorage(
            failWith: PlatformException(code: 'keystore'),
          ),
        );
      });

      test(
        'initialize açılışı BLOKLAMAZ',
        () => expectLater(sut.initialize(), completes),
      );

      test('okuma "oturum yok" olarak yorumlanır', () async {
        expect(await sut.hasAccessToken(), isFalse);
        expect(await sut.accessToken(), isNull);
      });

      test('yazma/silme fırlatmaz', () async {
        await expectLater(sut.persistSession(session), completes);
        await expectLater(sut.removePersistedSession(), completes);
      });
    });
  });

  group('SecureGotrueAsyncStorage', () {
    // gotrue verifier'ı bu anahtarla yazar (gotrue_client.dart:428).
    const verifierKey = 'supabase.auth.token-code-verifier';
    const verifier = 'pkce-verifier-abc123';

    late FakeSecureStorage storage;

    setUp(() {
      storage = FakeSecureStorage();
      SharedPreferences.setMockInitialValues({});
    });

    test('set → get → remove', () async {
      final sut = SecureGotrueAsyncStorage(storage: storage);

      expect(await sut.getItem(key: verifierKey), isNull);

      await sut.setItem(key: verifierKey, value: verifier);
      expect(await sut.getItem(key: verifierKey), verifier);
      expect(storage.data[verifierKey], verifier);

      await sut.removeItem(key: verifierKey);
      expect(await sut.getItem(key: verifierKey), isNull);
    });

    test('verifier SharedPreferences\'a YAZILMAZ', () async {
      final sut = SecureGotrueAsyncStorage(storage: storage);
      await sut.setItem(key: verifierKey, value: verifier);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(verifierKey), isNull);
    });

    test(
      'uçuştaki eski prefs verifier\'ı göçürülür (bekleyen onay linki kırılmaz)',
      () async {
        SharedPreferences.setMockInitialValues({verifierKey: verifier});
        final sut = SecureGotrueAsyncStorage(storage: storage);

        expect(await sut.getItem(key: verifierKey), verifier);
        expect(storage.data[verifierKey], verifier);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(verifierKey), isNull);
      },
    );

    test('göç anahtar başına EN FAZLA bir kez denenir', () async {
      final legacy = _CountingLegacy();
      final sut = SecureGotrueAsyncStorage(storage: storage, legacy: legacy);

      await sut.getItem(key: verifierKey);
      await sut.getItem(key: verifierKey);
      await sut.getItem(key: verifierKey);

      expect(
        legacy.getCalls,
        1,
        reason: 'getItem sıcak yolda, prefs her seferinde okunmamalı',
      );
    });

    test('Keystore reddi null döner, fırlatmaz', () async {
      final sut = SecureGotrueAsyncStorage(
        storage: FakeSecureStorage(
          failWith: PlatformException(code: 'keystore'),
        ),
      );

      expect(await sut.getItem(key: verifierKey), isNull);
      await expectLater(
        sut.setItem(key: verifierKey, value: verifier),
        completes,
      );
      await expectLater(sut.removeItem(key: verifierKey), completes);
    });
  });
}

class _CountingLegacy extends GotrueAsyncStorage {
  int getCalls = 0;

  @override
  Future<String?> getItem({required String key}) async {
    getCalls++;
    return null;
  }

  @override
  Future<void> setItem({required String key, required String value}) async {}

  @override
  Future<void> removeItem({required String key}) async {}
}
