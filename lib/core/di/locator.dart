/// Bağımlılık enjeksiyonu composition root (get_it, manuel kayıt).
///
/// Faz 2 Patch 4: kripto + anahtar yönetimi + kilit oturumu eklendi. Vault artık
/// unlock sonrası masterKey ile kurulur (global VaultCubit YOK).
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get_it/get_it.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/account/data/active_account_store.dart';
import '../../features/account/data/announcements_cache_store.dart';
import '../../features/account/data/feature_flags_cache_store.dart';
import '../../features/account/data/legacy_link_store.dart';
import '../../features/account/data/pending_confirmation_store.dart';
import '../../features/account/data/stable_device_id_store.dart';
import '../../features/account/data/supabase_announcements_repository.dart';
import '../../features/account/data/supabase_auth_repository.dart';
import '../../features/account/data/supabase_device_repository.dart';
import '../../features/account/data/supabase_feature_flags_repository.dart';
import '../../features/account/data/supabase_key_attributes_repository.dart';
import '../../features/account/domain/account_vault_manager.dart';
import '../../features/account/domain/announcements_repository.dart';
import '../../features/account/domain/auth_repository.dart';
import '../../features/account/domain/device_registrar.dart';
import '../../features/account/domain/device_repository.dart';
import '../../features/account/domain/feature_flags_repository.dart';
import '../../features/account/domain/feature_flags_service.dart';
import '../../features/account/domain/key_attributes_repository.dart';
import '../../features/auth/data/biometric_service_impl.dart';
import '../../features/auth/data/key_attributes_store.dart';
import '../../features/auth/domain/biometric_service.dart';
import '../../features/auth/domain/key_manager.dart';
import '../../features/import_export/data/aegis_parser.dart';
import '../../features/import_export/data/file_picker_document_port.dart';
import '../../features/import_export/data/twofas_parser.dart';
import '../../features/import_export/domain/backup_service.dart';
import '../../features/import_export/domain/dedupe.dart';
import '../../features/import_export/domain/file_port.dart';
import '../../features/import_export/domain/import_service.dart';
import '../../features/vault/data/catalog_cache_store.dart';
import '../../features/vault/data/supabase_catalog_repository.dart';
import '../../features/vault/data/supabase_token_repository.dart';
import '../../features/vault/data/vault_migration.dart';
import '../../features/vault/data/view_mode_store.dart';
import '../../features/vault/domain/catalog_repository.dart';
import '../../features/vault/domain/issuer_catalog_holder.dart';
import '../../features/vault/domain/remote_token_repository.dart';
import '../crypto/crypto_service.dart';
import '../crypto/sodium_crypto_service.dart';
import '../otp/otp_generator.dart';

final GetIt locator = GetIt.instance;

Future<void> configureDependencies() async {
  // Çekirdek OTP motoru — durumsuz, paylaşılabilir tekil.
  locator.registerLazySingleton<OtpGenerator>(() => const OtpGenerator());

  // Tüm vault/auth depoları aynı secure_storage instance'ını paylaşır.
  locator.registerLazySingleton<FlutterSecureStorage>(
      () => const FlutterSecureStorage());

  // E2E kripto servisi (libsodium/sumo). init() native binary'yi yükler — app
  // başlangıcında bir kez await edilir. Cihaz/simülatörde çalışır.
  final crypto = SodiumCryptoService();
  await crypto.init();
  locator.registerSingleton<CryptoService>(crypto);

  // Anahtar hiyerarşisi + metadata kalıcılığı.
  locator.registerLazySingleton<KeyManager>(
      () => KeyManager(locator<CryptoService>()));
  locator.registerLazySingleton<KeyAttributesStore>(
      () => KeyAttributesStore(storage: locator<FlutterSecureStorage>()));
  locator.registerLazySingleton<VaultMigration>(() => VaultMigration(
        crypto: locator<CryptoService>(),
        storage: locator<FlutterSecureStorage>(),
      ));

  // Görünüm tercihi (kart/liste) — secure_storage'da kalıcı.
  locator.registerLazySingleton<ViewModeStore>(
      () => ViewModeStore(storage: locator<FlutterSecureStorage>()));

  // Biyometrik kilit açma (Patch 5). KENDİ options'lı/namespace'li storage'ı var
  // (BiometricServiceImpl içinde) — paylaşılan no-options singleton DEĞİL, çünkü
  // bmk anahtarı OS-keystore biyometrik erişim kontrolü ister.
  locator.registerLazySingleton<BiometricService>(() => BiometricServiceImpl());

  // Faz 3 Patch 1: Supabase istemcisi + kimlik repository'si. `Supabase.initialize`
  // main.dart'ta DI'dan ÖNCE çağrılmış olmalı (singleton hazır).
  locator.registerLazySingleton<SupabaseClient>(() => Supabase.instance.client);
  locator.registerLazySingleton<AuthRepository>(
      () => SupabaseAuthRepository(locator<SupabaseClient>()));

  // Faz 3 Patch 2: kripto metadatası (key_attributes) sunucu deposu (upload/restore).
  locator.registerLazySingleton<KeyAttributesRepository>(
      () => SupabaseKeyAttributesRepository(locator<SupabaseClient>()));

  // Faz 3 Patch 3: şifreli token sunucu deposu (push/pull + Realtime tetikleyici).
  locator.registerLazySingleton<RemoteTokenRepository>(
      () => SupabaseTokenRepository(locator<SupabaseClient>()));

  // Multi-vault (kullanıcı kararı 7): aktif uid + per-uid legacy karar + onay store.
  locator.registerLazySingleton<ActiveAccountStore>(
      () => ActiveAccountStore(storage: locator<FlutterSecureStorage>()));
  locator.registerLazySingleton<LegacyLinkStore>(
      () => LegacyLinkStore(storage: locator<FlutterSecureStorage>()));
  locator.registerLazySingleton<PendingConfirmationStore>(
      () => PendingConfirmationStore(storage: locator<FlutterSecureStorage>()));
  locator.registerLazySingleton<AccountVaultManager>(() => AccountVaultManager(
        storage: locator<FlutterSecureStorage>(),
        activeStore: locator<ActiveAccountStore>(),
        legacyStore: locator<LegacyLinkStore>(),
        biometric: locator<BiometricService>(),
      ));

  // Faz 3 Patch 4: devices kaydı (owner-only). device_id GLOBAL (uid-bağımsız).
  locator.registerLazySingleton<DeviceRepository>(
      () => SupabaseDeviceRepository(locator<SupabaseClient>()));
  locator.registerLazySingleton<StableDeviceIdStore>(
      () => StableDeviceIdStore(storage: locator<FlutterSecureStorage>()));
  locator.registerLazySingleton<DeviceRegistrar>(() => DeviceRegistrar(
        repo: locator<DeviceRepository>(),
        idStore: locator<StableDeviceIdStore>(),
      ));

  // Faz 3 Patch 4: public read tablolar (catalog/feature_flags/announcements) — salt-okur.
  locator.registerLazySingleton<CatalogRepository>(
      () => SupabaseCatalogRepository(locator<SupabaseClient>()));
  locator.registerLazySingleton<CatalogCacheStore>(
      () => CatalogCacheStore(storage: locator<FlutterSecureStorage>()));
  locator.registerLazySingleton<IssuerCatalogHolder>(() => IssuerCatalogHolder(
        repo: locator<CatalogRepository>(),
        cache: locator<CatalogCacheStore>(),
      ));

  locator.registerLazySingleton<FeatureFlagsRepository>(
      () => SupabaseFeatureFlagsRepository(locator<SupabaseClient>()));
  locator.registerLazySingleton<FeatureFlagsCacheStore>(
      () => FeatureFlagsCacheStore(storage: locator<FlutterSecureStorage>()));
  locator.registerLazySingleton<FeatureFlagsService>(() => FeatureFlagsService(
        repo: locator<FeatureFlagsRepository>(),
        cache: locator<FeatureFlagsCacheStore>(),
      ));

  locator.registerLazySingleton<AnnouncementsRepository>(
      () => SupabaseAnnouncementsRepository(locator<SupabaseClient>()));
  locator.registerLazySingleton<AnnouncementsCacheStore>(
      () => AnnouncementsCacheStore(storage: locator<FlutterSecureStorage>()));

  // Faz 5 Patch 1 — import / şifreli export. YENİ kripto primitifi YOK:
  // BackupService aynı `CryptoService` (Argon2id + XChaCha20-Poly1305) üstünde
  // çalışır, KDF maliyetleri `defaultKdfParams()` tek kaynağından gelir.
  locator.registerLazySingleton<BackupService>(
      () => BackupService(locator<CryptoService>()));

  // Sistem dosya seçici portu (file_picker). Picker app'i arka plana attığı için
  // ÇAĞIRAN, VaultLockCubit.beginSystemFileFlow/endSystemFileFlow ile sarmalar.
  locator.registerLazySingleton<DocumentPort>(
      () => const FilePickerDocumentPort());

  // Kaynak parser'lar burada bağlanır; `detector`/`keyOf` GEÇİLMEZ, böylece
  // üretimde her zaman gerçek `detectSource` / `dedupeKey` kullanılır.
  //
  // `canonicalizeResolver` ise ÜRETİM bağlantısıdır (denetim A2): VaultCubit
  // token'ı vault'a yazarken issuer'ı AYNI `IssuerCatalogHolder` ile kanonik ada
  // çevirir ("github.com" → "GitHub"). Önizleme ham issuer ile dedupe etseydi
  // aynı dosyanın ikinci import'u vault'taki "GitHub" ile eşleşmez, token
  // ÇİFTLENİRDİ. Resolver (düz fonksiyon değil) çünkü her import'ta TAZE katalog
  // anlık görüntüsü alınmalı ve worker isolate'a giden closure yalnız o
  // (değişmez) anlık görüntüyü yakalamalı — holder/repository'yi ASLA.
  locator.registerLazySingleton<ImportService>(() => ImportService(
        backup: locator<BackupService>(),
        parsers: const [AegisParser(), TwoFasParser()],
        canonicalizeResolver: () =>
            canonicalizerFor(locator<IssuerCatalogHolder>().current),
      ));
}
