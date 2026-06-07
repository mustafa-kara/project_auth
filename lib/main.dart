import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'core/crypto/crypto_service.dart';
import 'core/di/locator.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/data/key_attributes_store.dart';
import 'features/auth/domain/biometric_service.dart';
import 'features/auth/domain/key_manager.dart';
import 'features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'features/vault/data/encrypted_vault_repository.dart';
import 'features/vault/data/vault_migration.dart';
import 'features/vault/presentation/bloc/vault_cubit.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureDependencies();
  // Faz 3: await Supabase.initialize(url:, publishableKey:) burada eklenecek.
  runApp(const AuthenticatorApp());
}

class AuthenticatorApp extends StatefulWidget {
  const AuthenticatorApp({super.key});

  @override
  State<AuthenticatorApp> createState() => _AuthenticatorAppState();
}

class _AuthenticatorAppState extends State<AuthenticatorApp>
    with WidgetsBindingObserver {
  late final VaultLockCubit _lock;
  late final AppRouterBundle _bundle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    final migration = locator<VaultMigration>();
    _lock = VaultLockCubit(
      keyManager: locator<KeyManager>(),
      attrsStore: locator<KeyAttributesStore>(),
      biometric: locator<BiometricService>(),
      migrate: (masterKey) => migration.migrateIfNeeded(masterKey: masterKey),
      deleteKeys: (keys) async {
        final storage = locator<FlutterSecureStorage>();
        for (final k in keys) {
          await storage.delete(key: k);
        }
      },
    )..bootstrap();

    _bundle = createAppRouter(
      _lock,
      // Unlocked subtree VaultCubit'i masterKey'li EncryptedVaultRepository ile kurar.
      // Sahiplik lock cubit'te; repo handle'ı dispose etmez.
      vaultCubitBuilder: () => VaultCubit(EncryptedVaultRepository(
        masterKey: _lock.masterKey,
        crypto: locator<CryptoService>(),
        storage: locator<FlutterSecureStorage>(),
      )),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Patch 5: paused/inactive AYRI iletilir. `inactive` biyometri sistem prompt'u
    // sırasında da gelebilir → cubit prompt-in-flight ise onu abort'tan muaf tutar
    // (reviewer 2.tur [P1]). `paused` (gerçek arka plan) her zaman kilit/abort.
    if (state == AppLifecycleState.paused) {
      _lock.onAppBackgrounded(paused: true);
    } else if (state == AppLifecycleState.inactive) {
      _lock.onAppBackgrounded(paused: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bundle.refresh.dispose(); // go_router refreshListenable'ı dispose etmez
    _lock.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<VaultLockCubit>.value(
      value: _lock,
      child: MaterialApp.router(
        title: 'Authenticator',
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        routerConfig: _bundle.router,
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
