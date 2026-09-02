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
import 'features/account/domain/announcements_repository.dart';
import 'features/account/domain/device_registrar.dart';
import 'features/account/domain/feature_flags_service.dart';
import 'features/account/domain/key_attributes_repository.dart';
import 'features/account/data/active_account_store.dart';
import 'features/account/data/announcements_cache_store.dart';
import 'features/account/data/attrs_dirty_store.dart';
import 'features/account/data/pending_confirmation_store.dart';
import 'features/account/data/reset_pending_store.dart';
import 'features/account/presentation/bloc/session_cubit.dart';
import 'features/account/presentation/bloc/session_state.dart';
import 'features/auth/data/key_attributes_store.dart';
import 'features/auth/domain/biometric_service.dart';
import 'features/auth/domain/key_manager.dart';
import 'features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'features/vault/data/encrypted_vault_repository.dart';
import 'features/vault/data/last_sync_store.dart';
import 'features/vault/data/live_sync_pref_store.dart';
import 'features/vault/data/vault_migration.dart';
import 'features/vault/data/view_mode_store.dart';
import 'features/vault/domain/issuer_catalog_holder.dart';
import 'features/vault/domain/remote_token_repository.dart';
import 'features/vault/domain/token_sync_service.dart';
import 'features/vault/presentation/bloc/vault_cubit.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Fail fast (debug + release) when the Supabase dart-defines are missing or
  // malformed — no embedded fallback, so a misconfigured build must not connect
  // to an unintended project. Letting the error escape an async `main()` would
  // surface as an unhandled zone error and leave a BLACK SCREEN with no hint,
  // so render the reason instead (review [P2]).
  try {
    SupabaseConfig.ensureConfigured();
  } catch (e) {
    runApp(ConfigErrorApp(details: e.toString()));
    return;
  }
  // Faz 3 Patch 1: kimlik katmanı. PKCE → e-posta onay deep-link'ini güvenli tamamlar.
  await Supabase.initialize(
    url: SupabaseConfig.url,
    publishableKey: SupabaseConfig.publishableKey,
    authOptions: const FlutterAuthClientOptions(
      authFlowType: AuthFlowType.pkce,
    ),
  );
  await configureDependencies();
  // Read the persisted active uid BEFORE the first frame so the initial vault
  // stack is built in the correct namespace. Without this we'd start in the
  // legacy ('') namespace and only switch once the session resolves — wasted
  // legacy bootstrap + a wrong-namespace window under slow storage. Best-effort:
  // on read failure fall back to '' (session resolution still corrects it).
  String initialPrefix = '';
  try {
    final uid = await locator<ActiveAccountStore>().read();
    if (uid != null && uid.isNotEmpty) {
      initialPrefix = AccountVaultManager.prefixFor(uid);
    }
  } catch (_) {
    /* fall back to legacy ''; _onSession re-derives on signedIn */
  }
  runApp(AuthenticatorApp(initialPrefix: initialPrefix));
}

/// Rendered instead of the app when the Supabase dart-defines are missing or
/// malformed. Deliberately dependency-free (no DI, no theme, no Supabase): it
/// must be able to boot when nothing else could. The body is the raw validator
/// message — this screen only ever appears on a misconfigured BUILD, so it is
/// addressed to the developer packaging it, not to an end user.
class ConfigErrorApp extends StatelessWidget {
  const ConfigErrorApp({super.key, required this.details});

  /// Developer-facing reason (`StateError.toString()`), shown verbatim.
  final String details;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline, size: 48),
                  const SizedBox(height: 16),
                  const Text(
                    'Yapılandırma hatası',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Text(details, style: const TextStyle(fontSize: 13)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AuthenticatorApp extends StatefulWidget {
  const AuthenticatorApp({super.key, this.initialPrefix = ''});

  /// Vault namespace prefix to build the initial stack with (from the persisted
  /// active uid). Empty = legacy/uid-less. [_onSession] re-derives the correct
  /// prefix once the Supabase session resolves to signedIn.
  final String initialPrefix;

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

    // Build the initial vault stack with the persisted active uid's namespace
    // (resolved in main() before first frame; empty = legacy/uid-less).
    _activePrefix = widget.initialPrefix;
    _buildVaultStack(_activePrefix);

    // Oturum signedIn olunca aktif uid'in namespace'ine geç (gerekirse yeniden kur).
    // Subscription field'da tutulur (dispose'ta cancel) + `onError` ZORUNLU (cubit
    // hatayı stream'e iletebilir → zone'a düşmesin). _onSession async → unawaited +
    // kendi try/catch'i (setActive secure-storage yazımı fail edebilir — reviewer [P3]).
    _sessionSub = _session.stream.listen(
      (s) => unawaited(_onSession(s)),
      onError: (Object _) {
        /* SessionCubit error'u state'e yansıtır; burada yut */
      },
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

    // Faz 3 Patch 4 — signedIn best-effort kancaları (uid değişmese de her signedIn'de):
    //   • cihaz kaydı (device_id üret + register; idempotent upsert)
    //   • flag/catalog/announcements cache ısıt (kill-switch + kanonikleştirme + duyuru)
    // Hepsi unawaited + kendi try/catch'i (kullanıcıyı/izolasyonu bloklamaz).
    unawaited(locator<DeviceRegistrar>().onSignedIn(uid));
    unawaited(locator<FeatureFlagsService>().refresh());
    unawaited(locator<IssuerCatalogHolder>().refresh());

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
    } catch (_) {
      /* izolasyon etkilenmez; sonraki açılışta yeniden denenir */
    }
  }

  /// VaultLockCubit + router'ı verilen namespace prefix'iyle kurar.
  void _buildVaultStack(String prefix) {
    final storage = locator<FlutterSecureStorage>();
    final migration = VaultMigration(
      crypto: locator<CryptoService>(),
      storage: storage,
      keyPrefix: prefix,
    );
    // Faz 3 Patch 2: uid prefix'ten türetilir ('<uid>/' → '<uid>'; boş → null).
    // legacy/uid-siz vault (prefix='') → uid=null → restore/upload NO-OP (Patch 1 ile
    // tutarlı; account-linking sonrası uid namespace'ine geçince aktifleşir).
    final uid = prefix.isEmpty ? null : prefix.substring(0, prefix.length - 1);
    _lock = VaultLockCubit(
      keyManager: locator<KeyManager>(),
      attrsStore: KeyAttributesStore(storage: storage, keyPrefix: prefix),
      biometric: locator<BiometricService>(),
      remoteRepo: locator<KeyAttributesRepository>(),
      // Security review finding 1 — reset must also wipe this uid's server token
      // rows (not just key_attributes). Used by resetVault only; null for legacy
      // (uid == null) → remote wipe is a no-op there.
      remoteTokenRepo: locator<RemoteTokenRepository>(),
      uid: uid,
      // Faz 3 Patch 3 (Adım K): changePassword sonrası sunucu UPDATE retry marker'ı.
      attrsDirtyStore: AttrsDirtyStore(storage: storage, keyPrefix: prefix),
      // Finding 1 (round 2): offline reset'in borçlu kaldığı remote tombstone retry marker'ı.
      resetPendingStore: ResetPendingStore(storage: storage, keyPrefix: prefix),
      migrate: (masterKey) => migration.migrateIfNeeded(masterKey: masterKey),
      deleteKeys: (keys) async {
        // Namespace'li reset: forUser(prefix) anahtarlarını sil (prefix boşsa Faz2 all).
        final target = prefix.isEmpty ? keys : VaultStorageKeys.forUser(prefix);
        for (final k in target) {
          await storage.delete(key: k);
        }
      },
    )..bootstrap();

    // Faz 3 Patch 3 — per-uid token sync store'ları (canlı tercih Settings'e de gider).
    final liveSyncStore = LiveSyncPrefStore(
      storage: storage,
      keyPrefix: prefix,
    );

    _bundle = createAppRouter(
      _lock,
      session: _session,
      vaultCubitBuilder: () =>
          _buildVaultCubit(prefix, uid, storage, liveSyncStore),
      // Aktif uid namespace'li ViewModeStore (reviewer [P3] — per-uid tercih).
      viewModeStoreBuilder: () =>
          ViewModeStore(storage: storage, keyPrefix: prefix),
      liveSyncStoreBuilder: () => liveSyncStore,
      // Faz 3 Patch 4 — Settings duyuru bölümü + flag-reaktif toggle için global provider'lar.
      shellWrapper: (child) => MultiRepositoryProvider(
        providers: [
          RepositoryProvider<AnnouncementsRepository>.value(
            value: locator<AnnouncementsRepository>(),
          ),
          RepositoryProvider<AnnouncementsCacheStore>.value(
            value: locator<AnnouncementsCacheStore>(),
          ),
          // token_sync_enabled değişince Settings toggle'ı reaktif gizlensin/görünsün.
          RepositoryProvider<FeatureFlagsService>.value(
            value: locator<FeatureFlagsService>(),
          ),
        ],
        child: child,
      ),
    );
  }

  /// Unlocked subtree'de `VaultCubit` + (uid varsa) `TokenSyncService` kurar.
  ///
  /// TEK `EncryptedVaultRepository` instance: hem `VaultRepository` (VaultCubit) hem
  /// `RawTokenStore` (sync). `uid == null` (legacy) → `sync: null` (NO-OP, byte-identical).
  /// Sync callback'leri cubit'e bağlıdır → cubit ÖNCE kurulur, sonra service'i set ederiz.
  VaultCubit _buildVaultCubit(
    String prefix,
    String? uid,
    FlutterSecureStorage storage,
    LiveSyncPrefStore liveSyncStore,
  ) {
    final repo = EncryptedVaultRepository(
      masterKey: _lock.masterKey,
      crypto: locator<CryptoService>(),
      storage: storage,
      keyPrefix: prefix,
    );
    // Faz 3 Patch 4 — token_sync_enabled kill-switch + issuer kanonikleştirme servisleri.
    final flags = locator<FeatureFlagsService>();
    final catalogHolder = locator<IssuerCatalogHolder>();
    if (uid == null) {
      // legacy/uid-siz → sync yok; ama issuer kanonikleştirme yine çalışabilir (katalog public).
      return VaultCubit(
        repo,
        issuerCatalogResolver: () => catalogHolder.current,
      );
    }
    late VaultCubit cubit;
    final sync = TokenSyncService(
      remote: locator<RemoteTokenRepository>(),
      store: repo, // EncryptedVaultRepository RawTokenStore'u da implement eder
      lastSync: LastSyncStore(storage: storage, keyPrefix: prefix),
      uid: uid,
      // Merge import yazımı VaultCubit sequencer'ı ALTINDA → kullanıcı add/delete ile
      // yarışmaz (reviewer [P1]). Service importRemote'u DOĞRUDAN çağırmaz.
      mergeRemote: (rows, cursor) => cubit.applyRemoteMerge(rows, cursor),
      onStatus: (s) => cubit.updateSyncState(s),
      // Adım F — kill-switch: gate TokenSyncService İÇİNDE (Realtime bypass kapalı);
      // flag false'a dönünce self-subscribe disableLive; flag true + livePref → enableLive.
      isEnabled: () => flags.isEnabled('token_sync_enabled', fallback: true),
      flagListenable: flags.listenable,
      livePreferenceResolver: liveSyncStore.read,
    );
    cubit = VaultCubit(
      repo,
      sync: sync,
      rawStore: repo,
      // Adım F — start öncesi flag bounded çözülür (cache-ready garantisi); flag false → start yok.
      tokenSyncEnabled: () =>
          flags.isEnabled('token_sync_enabled', fallback: true),
      ensureTokenSyncReady: flags.ensureLoaded,
      // Adım E — add-token issuer kanonikleştirme (güncel katalog; boş → no-op).
      issuerCatalogResolver: () => catalogHolder.current,
    );
    // Canlı tercih: load() start(live:)'dan ÖNCE bunu await eder (reviewer [P2] — race yok).
    cubit.liveSyncResolver = liveSyncStore.read;
    return cubit;
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
    } else if (state == AppLifecycleState.resumed) {
      // Faz 5 Patch 1 (plan §3.2) — sistem dosya seçici akışı arka plan kilidini
      // BÜTÇELİ olarak askıya alır. Bütçe biz yokken dolduysa muafiyet geçersizdir:
      // muafiyeti kapat ve arka plana geçmiş gibi HEMEN kilitle (uzun süre arka
      // planda kalmış bir cihaz muafiyetten faydalanmasın).
      // (`endSystemFileFlow` bütçe aşımını kendisi de uygular; buradaki
      // `onAppBackgrounded` ÇİFT GÜVENLİK — kilitli state'te no-op'tur.)
      if (_lock.systemFileFlowExpired) {
        _lock.endSystemFileFlow();
        _lock.onAppBackgrounded(paused: true);
      }
      // Faz 3 Patch 4 — resume'da device last_seen heartbeat (best-effort; 0 satır →
      // register-fallback). Yalnız signedIn iken (uid var). Vault kilidini etkilemez.
      final uid = _session.currentUid;
      if (uid != null && _session.state.status == SessionStatus.signedIn) {
        unawaited(locator<DeviceRegistrar>().onResumed(uid));
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionSub?.cancel(); // root lifecycle sahipliği (reviewer [P3])
    _bundle
        .dispose(); // go_router refreshListenable'ı dispose etmez (her notifier)
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
