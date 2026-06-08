import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config/supabase_config.dart';
import 'core/crypto/crypto_service.dart';
import 'core/di/locator.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/account/domain/account_vault_manager.dart';
import 'features/account/domain/auth_repository.dart';
import 'features/account/data/pending_confirmation_store.dart';
import 'features/account/presentation/bloc/session_cubit.dart';
import 'features/account/presentation/bloc/session_state.dart';
import 'features/auth/data/key_attributes_store.dart';
import 'features/auth/domain/biometric_service.dart';
import 'features/auth/domain/key_manager.dart';
import 'features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'features/vault/data/encrypted_vault_repository.dart';
import 'features/vault/data/vault_migration.dart';
import 'features/vault/data/view_mode_store.dart';
import 'features/vault/presentation/bloc/vault_cubit.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Faz 3 Patch 1: kimlik katmanı. PKCE → e-posta onay deep-link'ini güvenli tamamlar.
  await Supabase.initialize(
    url: SupabaseConfig.url,
    publishableKey: SupabaseConfig.publishableKey,
    authOptions:
        const FlutterAuthClientOptions(authFlowType: AuthFlowType.pkce),
  );
  await configureDependencies();
  runApp(const AuthenticatorApp());
}

class AuthenticatorApp extends StatefulWidget {
  const AuthenticatorApp({super.key});

  @override
  State<AuthenticatorApp> createState() => _AuthenticatorAppState();
}

class _AuthenticatorAppState extends State<AuthenticatorApp>
    with WidgetsBindingObserver {
  late final SessionCubit _session;
  late VaultLockCubit _lock;
  late AppRouterBundle _bundle;

  /// Oturum stream aboneliği — root lifecycle'da sahiplenilir + `dispose`'ta cancel
  /// edilir (reviewer [P3]).
  StreamSubscription<SessionState>? _sessionSub;

  /// Aktif vault namespace prefix'i (`'<uid>/'` veya boş). uid değişince yeniden kurulur.
  String _activePrefix = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    final manager = locator<AccountVaultManager>();

    _session = SessionCubit(
      auth: locator<AuthRepository>(),
      pendingStore: locator<PendingConfirmationStore>(),
      linkRequiredResolver: manager.linkRequired,
      onAuthSignedOut: () => _lock.onAuthSignedOut(),
    );

    // İlk vault stack'i kayıtlı aktif uid'in namespace'iyle kur (yoksa boş = legacy).
    _activePrefix = '';
    _buildVaultStack(_activePrefix);

    // Oturum signedIn olunca aktif uid'in namespace'ine geç (gerekirse yeniden kur).
    // Subscription field'da tutulur (dispose'ta cancel) + `onError` ZORUNLU (cubit
    // hatayı stream'e iletebilir → zone'a düşmesin). _onSession async → unawaited +
    // kendi try/catch'i (setActive secure-storage yazımı fail edebilir — reviewer [P3]).
    _sessionSub = _session.stream.listen(
      (s) => unawaited(_onSession(s)),
      onError: (Object _) {/* SessionCubit error'u state'e yansıtır; burada yut */},
    );

    _session.bootstrap();
  }

  /// signedIn + linkRequired=false iken aktif uid'in namespace'i doğru değilse
  /// vault stack'i o namespace ile yeniden kurar + bootstrap eder (reviewer [P1]).
  ///
  /// **SIRA — izolasyon önceliği (reviewer [P3]):** ÖNCE bellekteki namespace'i doğru
  /// uid'e geçir (vault izolasyonu BU oturumda kesin sağlanır), SONRA aktif uid'i
  /// persist et (yalnız bir sonraki açılış için gerekli). `setActive` (secure storage)
  /// fail ederse kullanıcı YİNE doğru uid namespace'inde kalır (legacy `''` stack'inde
  /// sessizce KALMAZ — yanlış vault sızıntısı önlenir); persist sonraki event'te yeniden denenir.
  Future<void> _onSession(SessionState s) async {
    if (s.status != SessionStatus.signedIn || s.linkRequired) return;
    final uid = _session.currentUid;
    if (uid == null) return;
    final prefix = AccountVaultManager.prefixFor(uid);
    if (prefix == _activePrefix) return;

    // 1) İzolasyon ÖNCE: bellekteki stack'i doğru uid namespace'ine geçir.
    if (!mounted) return;
    setState(() {
      _activePrefix = prefix;
      _rebuildVaultStack(prefix);
    });

    // 2) Persist (best-effort): aktif uid'i kaydet (yalnız bir sonraki AÇILIŞ için).
    //    Fail ederse bu oturum zaten doğru namespace'te → izolasyon korunur. Persist
    //    edilemezse sonraki app açılışında (_activePrefix='' başlar) bootstrap yeniden dener.
    try {
      await locator<AccountVaultManager>().setActive(uid);
    } catch (_) {/* izolasyon etkilenmez; sonraki açılışta yeniden denenir */}
  }

  /// VaultLockCubit + router'ı verilen namespace prefix'iyle kurar.
  void _buildVaultStack(String prefix) {
    final storage = locator<FlutterSecureStorage>();
    final migration = VaultMigration(
      crypto: locator<CryptoService>(),
      storage: storage,
      keyPrefix: prefix,
    );
    _lock = VaultLockCubit(
      keyManager: locator<KeyManager>(),
      attrsStore: KeyAttributesStore(storage: storage, keyPrefix: prefix),
      biometric: locator<BiometricService>(),
      migrate: (masterKey) => migration.migrateIfNeeded(masterKey: masterKey),
      deleteKeys: (keys) async {
        // Namespace'li reset: forUser(prefix) anahtarlarını sil (prefix boşsa Faz2 all).
        final target = prefix.isEmpty
            ? keys
            : VaultStorageKeys.forUser(prefix);
        for (final k in target) {
          await storage.delete(key: k);
        }
      },
    )..bootstrap();

    _bundle = createAppRouter(
      _lock,
      session: _session,
      vaultCubitBuilder: () => VaultCubit(EncryptedVaultRepository(
        masterKey: _lock.masterKey,
        crypto: locator<CryptoService>(),
        storage: storage,
        keyPrefix: prefix,
      )),
      // Aktif uid namespace'li ViewModeStore (reviewer [P3] — per-uid tercih).
      viewModeStoreBuilder: () =>
          ViewModeStore(storage: storage, keyPrefix: prefix),
    );
  }

  /// uid değişince eski stack'i kapatıp yenisini kurar.
  void _rebuildVaultStack(String prefix) {
    final old = _bundle;
    final oldLock = _lock;
    _buildVaultStack(prefix);
    // Eski kaynakları bir sonraki frame'de kapat (aktif kullanım bitince).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      old.dispose();
      oldLock.close();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Patch 5: paused/inactive AYRI iletilir. `inactive` biyometri sistem prompt'u
    // sırasında da gelebilir → cubit prompt-in-flight ise onu abort'tan muaf tutar.
    // `paused` (gerçek arka plan) her zaman kilit/abort.
    if (state == AppLifecycleState.paused) {
      _lock.onAppBackgrounded(paused: true);
    } else if (state == AppLifecycleState.inactive) {
      _lock.onAppBackgrounded(paused: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionSub?.cancel(); // root lifecycle sahipliği (reviewer [P3])
    _bundle.dispose(); // go_router refreshListenable'ı dispose etmez (her notifier)
    _lock.close();
    _session.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<SessionCubit>.value(value: _session),
        BlocProvider<VaultLockCubit>.value(value: _lock),
      ],
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
