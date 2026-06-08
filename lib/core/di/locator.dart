/// Bağımlılık enjeksiyonu composition root (get_it, manuel kayıt).
///
/// Faz 2 Patch 4: kripto + anahtar yönetimi + kilit oturumu eklendi. Vault artık
/// unlock sonrası masterKey ile kurulur (global VaultCubit YOK).
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get_it/get_it.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/account/data/active_account_store.dart';
import '../../features/account/data/legacy_link_store.dart';
import '../../features/account/data/pending_confirmation_store.dart';
import '../../features/account/data/supabase_auth_repository.dart';
import '../../features/account/domain/account_vault_manager.dart';
import '../../features/account/domain/auth_repository.dart';
import '../../features/auth/data/biometric_service_impl.dart';
import '../../features/auth/data/key_attributes_store.dart';
import '../../features/auth/domain/biometric_service.dart';
import '../../features/auth/domain/key_manager.dart';
import '../../features/vault/data/vault_migration.dart';
import '../../features/vault/data/view_mode_store.dart';
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
}
