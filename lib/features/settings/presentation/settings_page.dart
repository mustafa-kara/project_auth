/// Ayarlar ekranı (Faz 2 Patch 5) — şimdilik yalnız biyometrik kilit açma.
///
/// unlocked-only (masterKey bellekte; guard `/settings`'e yalnız unlocked'ta izin
/// verir). Biyometri aç/kapat `SwitchListTile`:
///   - değer = `biometricEnrolled` (bu cihazda enroll edilmiş mi)
///   - switch ETKİN mi = `deviceBiometricAvailable` (cihaz yeteneği) — enrolled
///     DEĞİL (yoksa yeni kullanıcı hiç açamazdı; reviewer 3.tur [P1])
///   - kapatma availability'den bağımsız (lockout'ta bile kapatılabilir)
/// Hata (enroll iptal/lockout/unavailable) → inline SnackBar; state değişmediği
/// için switch eski haline döner. Tasarım: Design.md dili (Material 3 + tokens).
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/ui/tokens.dart';
import '../../../core/ui/widgets/status_badge.dart';
import '../../account/data/announcements_cache_store.dart';
import '../../account/domain/announcements_repository.dart';
import '../../account/domain/feature_flags_service.dart';
import '../../auth/domain/biometric_exceptions.dart';
import '../../auth/presentation/bloc/vault_lock_cubit.dart';
import '../../vault/data/live_sync_pref_store.dart';
import '../../vault/presentation/bloc/vault_cubit.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _busy = false;

  /// Canlı senkron tercihi (LiveSyncPrefStore'dan yüklenir). null = yüklenmedi.
  bool? _liveSync;
  bool _liveBusy = false;

  /// Görünür duyurular (Faz 3 Patch 4 — cache→ağ; audience filtreli). null = yüklenmedi/yok.
  List<Announcement>? _announcements;

  @override
  void initState() {
    super.initState();
    _loadLiveSyncPref();
    _loadAnnouncements();
  }

  /// Duyuruları yükle: ÖNCE cache (anında), SONRA ağ refresh (best-effort). Servis yoksa
  /// (RepositoryProvider yok) bölüm gizli kalır (Patch 3 defensif kalıbı).
  Future<void> _loadAnnouncements() async {
    AnnouncementsRepository? repo;
    AnnouncementsCacheStore? cache;
    try {
      repo = context.read<AnnouncementsRepository>();
      cache = context.read<AnnouncementsCacheStore>();
    } catch (_) {
      return; // servis yok → bölüm gizli
    }
    // 1) Cache (offline/anında).
    final cached = await cache.read();
    if (cached != null && mounted) {
      setState(() => _announcements = visibleAnnouncements(cached));
    }
    // 2) Ağ refresh (best-effort).
    try {
      final fresh = await repo.fetchAll();
      await cache.write(fresh);
      if (mounted) setState(() => _announcements = visibleAnnouncements(fresh));
    } catch (_) {
      // ağ hatası → cache'teki kalır (sessiz).
    }
  }

  Future<void> _loadLiveSyncPref() async {
    // RepositoryProvider yoksa (sync desteklenmiyor) toggle gizli kalır.
    LiveSyncPrefStore? store;
    try {
      store = context.read<LiveSyncPrefStore>();
    } catch (_) {
      store = null;
    }
    if (store == null) return;
    final v = await store.read();
    if (mounted) setState(() => _liveSync = v);
  }

  Future<void> _toggleLiveSync(bool enable) async {
    final messenger = ScaffoldMessenger.of(context);
    final vault = context.read<VaultCubit>();
    LiveSyncPrefStore? store;
    try {
      store = context.read<LiveSyncPrefStore>();
    } catch (_) {
      store = null;
    }
    setState(() => _liveBusy = true);
    try {
      await store?.write(enable);
      if (enable) {
        vault.enableLiveSync();
      } else {
        await vault.disableLiveSync();
      }
      if (mounted) setState(() => _liveSync = enable);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            enable
                ? 'Canlı senkron açıldı'
                : 'Canlı senkron kapatıldı (açılışta yine senkron olur)',
          ),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('İşlem başarısız — tekrar dene')),
      );
    } finally {
      if (mounted) setState(() => _liveBusy = false);
    }
  }

  Future<void> _toggleBiometric(bool enable) async {
    final cubit = context.read<VaultLockCubit>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      if (enable) {
        await cubit.enableBiometric();
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Biyometrik kilit açma etkinleştirildi'),
          ),
        );
      } else {
        await cubit.disableBiometric();
        messenger.showSnackBar(
          const SnackBar(content: Text('Biyometrik kilit açma kapatıldı')),
        );
      }
    } on BiometricUnavailable {
      messenger.showSnackBar(
        const SnackBar(content: Text('Bu cihazda biyometri kullanılamıyor')),
      );
    } on BiometricLockout {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Biyometri kilitlendi — sonra tekrar dene'),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('İşlem başarısız — tekrar dene')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enrolled = context.select<VaultLockCubit, bool>(
      (c) => c.state.biometricEnrolled,
    );
    final deviceAvailable = context.select<VaultLockCubit, bool>(
      (c) => c.state.deviceBiometricAvailable,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Ayarlar')),
      body: SafeArea(
        child: ListView(
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.fingerprint),
              title: const Text('Biyometrik kilit açma'),
              subtitle: Text(
                // enrolled ama cihaz uygun değil (biyometri seti değişti/lockout) →
                // kapatmaya yönlendir; aksi halde availability durumuna göre açıklama.
                enrolled && !deviceAvailable
                    ? 'Biyometri artık kullanılamıyor (cihaz ayarların değişmiş '
                          'olabilir). Kapatıp gerekirse tekrar açabilirsin.'
                    : deviceAvailable
                    ? 'Vault\'u parola yerine biyometriyle aç. Master parola + '
                          'recovery key her zaman çalışmaya devam eder.'
                    : 'Bu cihazda güçlü biyometri (parmak izi / yüz) kullanılamıyor.',
              ),
              // AÇMA (kapalı→açık) yalnız cihaz uygunsa (yoksa enroll/read fail eder).
              // KAPATMA (açık→kapalı) availability'den BAĞIMSIZ — enrolled iken cihaz
              // uygun olmasa bile kullanıcı temizleyebilmeli (reviewer P2: yorum
              // doğruydu ama kod `!deviceAvailable` ile kapatmayı da kilitliyordu).
              value: enrolled,
              onChanged: _busy
                  ? null
                  : (enrolled || deviceAvailable)
                  ? (v) => _toggleBiometric(v)
                  : null,
            ),
            // enrolled ama cihaz uygun değil → "kullanılamıyor" rozeti (warning,
            // ikon+metin; color-not-only — settings.md §4/§10). Anahtar yine
            // kapatılabilir (lockout değil).
            if (enrolled && !deviceAvailable)
              const Padding(
                padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: StatusBadge(
                    kind: StatusKind.warning,
                    icon: Icons.error_outline,
                    label: 'Şu an kullanılamıyor',
                  ),
                ),
              ),
            // İki-katman güvenlik notu (info ikon + ikincil metin — design.md §11).
            if (enrolled) _twoLayerNote(context),
            _buildLiveSyncTile(context),
            ..._buildBackupSection(context),
            ..._buildAnnouncements(context),
          ],
        ),
      ),
    );
  }

  /// İki-katman güvenlik notu (settings.md §4) — info ikon + ikincil metin.
  Widget _twoLayerNote(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              'Biyometri yalnız bir kısayoldur. Parolan ve kurtarma anahtarın '
              'her zaman çalışır.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Faz 5 Patch 1 — yedekleme ve aktarım bölümü (plan §5.2). Duyurulardan ÖNCE
  /// gelir: bunlar kullanıcının kendi verisiyle ilgili aksiyonlar, duyurular ise
  /// salt-okunur bilgi. Her iki rota da unlocked-only (guard beyaz listesi).
  List<Widget> _buildBackupSection(BuildContext context) {
    final theme = Theme.of(context);
    return [
      const Divider(height: 1),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
        child: Text(
          'YEDEKLEME VE AKTARIM',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.file_download_outlined),
        title: const Text('İçe aktar'),
        subtitle: const Text('Aegis veya 2FAS yedeğinden token aktar'),
        onTap: () => context.push(Routes.importData),
      ),
      ListTile(
        leading: const Icon(Icons.lock_outline),
        title: const Text('Şifreli yedek al'),
        subtitle: const Text(
          'Tokenlarını ayrı bir parolayla şifrelenmiş dosyaya aktar',
        ),
        onTap: () => context.push(Routes.exportData),
      ),
    ];
  }

  /// Faz 3 Patch 4 — duyurular salt-okunur bölüm. Boş/servis yoksa hiçbir şey göstermez.
  /// feature_flags UI'da GÖSTERİLMEZ (yalnız dahili — kullanıcı kararı 2).
  List<Widget> _buildAnnouncements(BuildContext context) {
    final items = _announcements;
    if (items == null || items.isEmpty) return const [];
    final theme = Theme.of(context);
    return [
      const Divider(height: 1),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
        child: Text(
          'YENİLİKLER',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      for (final a in items)
        ListTile(
          leading: const Icon(Icons.campaign_outlined),
          title: Row(
            children: [
              Flexible(child: Text(a.title)),
              const SizedBox(width: Gap.sm),
              const StatusBadge(
                kind: StatusKind.primary,
                icon: Icons.fiber_new_outlined,
                label: 'yeni',
              ),
            ],
          ),
          subtitle: Text(a.body), // uzun metin wrap (truncation yerine)
          isThreeLine: a.body.length > 60,
        ),
    ];
  }

  /// Faz 3 Patch 3 — canlı senkron (Realtime) toggle'ı. Yalnız sync destekleniyorsa
  /// (uid'li vault + pref yüklendi + `token_sync_enabled` flag açık) gösterilir.
  ///
  /// **Faz 3 Patch 4 (review [P2]) — flag-REAKTİF:** `FeatureFlagsService.listenable`'a
  /// abone `ListenableBuilder` → server `token_sync_enabled`'ı değiştirince toggle anında
  /// gizlenir/görünür (TokenSyncService aboneliği zaten kapatır; UI artık tutarlı:
  /// toggle görünür ⇔ sync etkin). Servis yoksa (legacy/test) eski tek-okuma davranışı.
  Widget _buildLiveSyncTile(BuildContext context) {
    FeatureFlagsService? flags;
    try {
      flags = context.read<FeatureFlagsService>();
    } catch (_) {
      flags = null;
    }
    if (flags == null) return _liveSyncTileBody(context);
    // Flag değişince yeniden çiz → vault.syncEnabled (flag snapshot'ına bağlı) taze okunur.
    return ListenableBuilder(
      listenable: flags.listenable,
      builder: (context, _) => _liveSyncTileBody(context),
    );
  }

  Widget _liveSyncTileBody(BuildContext context) {
    // VaultCubit yoksa (örn. yalnız VaultLockCubit'li ekranlar) toggle gizli.
    VaultCubit? vault;
    try {
      vault = context.read<VaultCubit>();
    } catch (_) {
      vault = null;
    }
    final live = _liveSync;
    // vault.syncEnabled = _sync != null && token_sync_enabled flag açık (taze okunur).
    if (vault == null || !vault.syncEnabled || live == null) {
      return const SizedBox.shrink();
    }
    return SwitchListTile(
      secondary: const Icon(Icons.cloud_sync_outlined),
      title: const Text('Canlı senkron'),
      subtitle: const Text(
        'Vault\'u diğer cihazlarla gerçek zamanlı senkronize et. Kapalıyken '
        'açılışta yine senkron olur; yalnız anlık güncelleme kapanır.',
      ),
      value: live,
      onChanged: _liveBusy ? null : (v) => _toggleLiveSync(v),
    );
  }
}
