/// `configureDependencies()` composition root testleri.
///
/// Kapsanan: KAYIT sözleşmesi — her tipin çözülebildiği, hiçbir fabrika
/// kurulumunun patlamadığı ve tekillerin GERÇEKTEN tek olduğu (iki `locator<T>()`
/// aynı örneği verir). Bir tip listeden düşerse ya da bir fabrika yeni bir
/// bağımlılık isteyip kayıt sırası bozulursa bu test kırmızıya döner.
///
/// **Host VM'de iki şey sahte:**
///  1. `SodiumCryptoService.init()` gerçek libsodium binary'sini `SodiumPlatform`
///     plugin'inden yükler; plain `flutter test` host'unda Flutter plugin'leri
///     kayıtlı DEĞİLDİR. `SodiumPlatform.instance` yazılabilir olduğu için
///     [_FakeSodiumPlatform] enjekte edilir — kripto ÇAĞRISI yapılmaz, yalnız
///     kayıt yolu yürütülür (gerçek kripto round-trip'i integration_test'te).
///  2. `Supabase.instance.client` `Supabase.initialize` şart koşar; sahte HTTP
///     istemcisi + `EmptyLocalStorage` + `detectSessionInUri: false` ile
///     kurulur → ne ağ ne de shared_preferences/app_links platform kanalı.
///
/// Kapsanmayan: fabrikaların ÜRETTİĞİ nesnelerin davranışı (kendi testlerinde)
/// ve `main.dart`'ın DI'yı çağırma sırası.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/crypto/crypto_service.dart';
import 'package:project_auth/core/crypto/sodium_crypto_service.dart';
import 'package:project_auth/core/di/locator.dart';
import 'package:project_auth/core/otp/otp_generator.dart';
import 'package:project_auth/features/account/data/active_account_store.dart';
import 'package:project_auth/features/account/data/announcements_cache_store.dart';
import 'package:project_auth/features/account/data/feature_flags_cache_store.dart';
import 'package:project_auth/features/account/data/legacy_link_store.dart';
import 'package:project_auth/features/account/data/pending_confirmation_store.dart';
import 'package:project_auth/features/account/data/stable_device_id_store.dart';
import 'package:project_auth/features/account/data/supabase_announcements_repository.dart';
import 'package:project_auth/features/account/data/supabase_auth_repository.dart';
import 'package:project_auth/features/account/data/supabase_device_repository.dart';
import 'package:project_auth/features/account/data/supabase_feature_flags_repository.dart';
import 'package:project_auth/features/account/data/supabase_key_attributes_repository.dart';
import 'package:project_auth/features/account/domain/account_vault_manager.dart';
import 'package:project_auth/features/account/domain/announcements_repository.dart';
import 'package:project_auth/features/account/domain/auth_repository.dart';
import 'package:project_auth/features/account/domain/device_registrar.dart';
import 'package:project_auth/features/account/domain/device_repository.dart';
import 'package:project_auth/features/account/domain/feature_flags_repository.dart';
import 'package:project_auth/features/account/domain/feature_flags_service.dart';
import 'package:project_auth/features/account/domain/key_attributes_repository.dart';
import 'package:project_auth/features/auth/data/biometric_service_impl.dart';
import 'package:project_auth/features/auth/data/key_attributes_store.dart';
import 'package:project_auth/features/auth/domain/biometric_service.dart';
import 'package:project_auth/features/auth/domain/key_manager.dart';
import 'package:project_auth/features/import_export/data/file_picker_document_port.dart';
import 'package:project_auth/features/import_export/domain/backup_service.dart';
import 'package:project_auth/features/import_export/domain/file_port.dart';
import 'package:project_auth/features/import_export/domain/import_service.dart';
import 'package:project_auth/features/vault/data/catalog_cache_store.dart';
import 'package:project_auth/features/vault/data/supabase_catalog_repository.dart';
import 'package:project_auth/features/vault/data/supabase_token_repository.dart';
import 'package:project_auth/features/vault/data/vault_migration.dart';
import 'package:project_auth/features/vault/data/view_mode_store.dart';
import 'package:project_auth/features/vault/domain/catalog_repository.dart';
import 'package:project_auth/features/vault/domain/issuer_catalog_holder.dart';
import 'package:project_auth/features/vault/domain/remote_token_repository.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart' show SodiumPlatform;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../support/fake_http_client.dart';

/// Hiçbir kripto çağrısını desteklemeyen sahte `SodiumSumo`. Yalnız `version`
/// gerçektir: `SodiumSumoInit.init()` debug modda sürüm kontrolü yapar.
/// Diğer her üye çağrılırsa test AÇIKÇA patlasın diye `noSuchMethod` fırlatır.
class _FakeSodiumSumo implements SodiumSumo {
  @override
  SodiumVersion get version => const SodiumVersion(26, 2, '1.0.20');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Sahte sodium: ${invocation.memberName} host VM testinde desteklenmez',
  );
}

/// Platform plugin'i yerine geçen sahte. `SodiumPlatform.instance` setter'ı
/// `PlatformInterface` token doğrulaması yaptığı için `extends` ŞART.
class _FakeSodiumPlatform extends SodiumPlatform {
  @override
  Future<Sodium> loadSodium() async => _FakeSodiumSumo();

  @override
  Future<SodiumSumo> loadSodiumSumo() async => _FakeSodiumSumo();
}

/// PKCE deposu varsayılanda shared_preferences kullanır (platform kanalı) —
/// host VM'de bellek içi karşılığı yeter.
class _MemoryPkceStorage implements GotrueAsyncStorage {
  final _items = <String, String>{};

  @override
  Future<String?> getItem({required String key}) async => _items[key];

  @override
  Future<void> removeItem({required String key}) async => _items.remove(key);

  @override
  Future<void> setItem({required String key, required String value}) async =>
      _items[key] = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// `configureDependencies()`'in kaydettiği HER tip. Yeni bir kayıt eklenince
  /// buraya da eklenmelidir — liste kasıtlı olarak elle tutulur (get_it kayıtlı
  /// tipleri numaralandıran bir API sunmaz).
  final resolvers = <String, Object Function()>{
    'OtpGenerator': () => locator<OtpGenerator>(),
    'FlutterSecureStorage': () => locator<FlutterSecureStorage>(),
    'CryptoService': () => locator<CryptoService>(),
    'KeyManager': () => locator<KeyManager>(),
    'KeyAttributesStore': () => locator<KeyAttributesStore>(),
    'VaultMigration': () => locator<VaultMigration>(),
    'ViewModeStore': () => locator<ViewModeStore>(),
    'BiometricService': () => locator<BiometricService>(),
    'SupabaseClient': () => locator<SupabaseClient>(),
    'AuthRepository': () => locator<AuthRepository>(),
    'KeyAttributesRepository': () => locator<KeyAttributesRepository>(),
    'RemoteTokenRepository': () => locator<RemoteTokenRepository>(),
    'ActiveAccountStore': () => locator<ActiveAccountStore>(),
    'LegacyLinkStore': () => locator<LegacyLinkStore>(),
    'PendingConfirmationStore': () => locator<PendingConfirmationStore>(),
    'AccountVaultManager': () => locator<AccountVaultManager>(),
    'DeviceRepository': () => locator<DeviceRepository>(),
    'StableDeviceIdStore': () => locator<StableDeviceIdStore>(),
    'DeviceRegistrar': () => locator<DeviceRegistrar>(),
    'CatalogRepository': () => locator<CatalogRepository>(),
    'CatalogCacheStore': () => locator<CatalogCacheStore>(),
    'IssuerCatalogHolder': () => locator<IssuerCatalogHolder>(),
    'FeatureFlagsRepository': () => locator<FeatureFlagsRepository>(),
    'FeatureFlagsCacheStore': () => locator<FeatureFlagsCacheStore>(),
    'FeatureFlagsService': () => locator<FeatureFlagsService>(),
    'AnnouncementsRepository': () => locator<AnnouncementsRepository>(),
    'AnnouncementsCacheStore': () => locator<AnnouncementsCacheStore>(),
    'BackupService': () => locator<BackupService>(),
    'DocumentPort': () => locator<DocumentPort>(),
    'ImportService': () => locator<ImportService>(),
  };

  setUpAll(() async {
    SodiumPlatform.instance = _FakeSodiumPlatform();
    await Supabase.initialize(
      url: 'https://locator-test.supabase.co',
      publishableKey: 'sb_publishable_fake',
      httpClient: RecordingHttpClient(),
      authOptions: FlutterAuthClientOptions(
        localStorage: const EmptyLocalStorage(),
        pkceAsyncStorage: _MemoryPkceStorage(),
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
      debug: false,
    );
  });

  setUp(() async {
    await configureDependencies();
  });

  tearDown(() async {
    await locator.reset();
  });

  test('configureDependencies() hata FIRLATMADAN tamamlanır', () {
    // setUp zaten çağırdı; kayıtların gerçekten oluştuğunu doğrula.
    expect(locator.isRegistered<CryptoService>(), isTrue);
    expect(locator.isRegistered<ImportService>(), isTrue);
  });

  test('kayıtlı HER tip çözülür (hiçbir fabrika patlamaz)', () {
    for (final entry in resolvers.entries) {
      expect(
        entry.value(),
        isNotNull,
        reason: '${entry.key} çözülemedi — kayıt sırası/bağımlılığı bozuk',
      );
    }
  });

  test('hepsi TEKİL: iki locator<T>() aynı örneği döndürür', () {
    for (final entry in resolvers.entries) {
      expect(
        identical(entry.value(), entry.value()),
        isTrue,
        reason: '${entry.key} her çözümde YENİ örnek üretiyor (tekil değil)',
      );
    }
  });

  test(
    'reset sonrası hiçbir tip kayıtlı kalmaz ve yeniden kurulabilir',
    () async {
      await locator.reset();
      expect(locator.isRegistered<CryptoService>(), isFalse);
      expect(locator.isRegistered<SupabaseClient>(), isFalse);

      // tearDown yeniden reset edecek; ikinci kurulum "already registered"
      // fırlatmamalı (fabrikalar durumsuz).
      await configureDependencies();
      expect(locator<ImportService>(), isNotNull);
    },
  );

  group('bağlantı (hangi implementasyon nereye)', () {
    test('Supabase tabanlı repository\'ler doğru sınıflara bağlı', () {
      expect(locator<AuthRepository>(), isA<SupabaseAuthRepository>());
      expect(
        locator<KeyAttributesRepository>(),
        isA<SupabaseKeyAttributesRepository>(),
      );
      expect(locator<RemoteTokenRepository>(), isA<SupabaseTokenRepository>());
      expect(locator<DeviceRepository>(), isA<SupabaseDeviceRepository>());
      expect(locator<CatalogRepository>(), isA<SupabaseCatalogRepository>());
      expect(
        locator<FeatureFlagsRepository>(),
        isA<SupabaseFeatureFlagsRepository>(),
      );
      expect(
        locator<AnnouncementsRepository>(),
        isA<SupabaseAnnouncementsRepository>(),
      );
    });

    test('port/servis soyutlamaları gerçek implementasyonlara bağlı', () {
      expect(locator<CryptoService>(), isA<SodiumCryptoService>());
      expect(locator<BiometricService>(), isA<BiometricServiceImpl>());
      expect(locator<DocumentPort>(), isA<FilePickerDocumentPort>());
    });

    test('SupabaseClient global Supabase örneğinden gelir', () {
      expect(locator<SupabaseClient>(), same(Supabase.instance.client));
    });
  });

  // Güvenlik denetimi P1-2 / P3-1 — iki SESSİZ plugin varsayılanını sabitler.
  // Bunlar kod okunarak fark edilmez (options hiç geçilmiyordu) ve bir paket
  // yükseltmesi altımızdan değiştirebilir; test tam da bu yüzden var.
  // Beklenen map anahtarları kurulu paketten alınmıştır:
  // flutter_secure_storage-10.3.1/lib/options/android_options.dart (`toMap`) ve
  // .../options/apple_options.dart (`toMap`).
  group('secure storage options (P1-2 / P3-1)', () {
    test('Android: resetOnError KAPALI (sessiz veri silme yok)', () {
      final storage = locator<FlutterSecureStorage>();
      expect(
        storage.aOptions.toMap()['resetOnError'],
        'false',
        reason:
            'true olursa Keystore hatası vault_key_attributes_v1\'i SİLER ve '
            'bootstrap sessizce "uninitialized" görüp setup ekranı açar',
      );
    });

    test(
      'Android: migrateWithBackup AÇIK (algoritma göçü çökme-dayanıklı)',
      () {
        expect(
          locator<FlutterSecureStorage>().aOptions.toMap()['migrateWithBackup'],
          'true',
        );
      },
    );

    test('iOS: accessibility unlocked_this_device (yedekle göç etmez)', () {
      final storage = locator<FlutterSecureStorage>();
      expect(
        storage.iOptions.toMap()['accessibility'],
        'unlocked_this_device',
        reason:
            'varsayılan `unlocked` cihaza bağlı DEĞİL → şifreli iTunes/Finder '
            'yedeğiyle yeni cihaza taşınır (CRYPTO.md §12: yeni cihaz sunucudan '
            'restore eder, keychain göçüyle değil)',
      );
      // iCloud Keychain senkronu zaten kapalı olmalı (paket varsayılanı) —
      // birlikte "yalnız bu cihaz" garantisini verirler.
      expect(storage.iOptions.toMap()['synchronizable'], 'false');
    });
  });
}
