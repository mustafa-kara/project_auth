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

  @override
  void initState() {
    super.initState();
    _loadLiveSyncPref();
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
      messenger.showSnackBar(SnackBar(
          content: Text(enable
              ? 'Canlı senkron açıldı'
              : 'Canlı senkron kapatıldı (açılışta yine senkron olur)')));
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text('İşlem başarısız — tekrar dene')));
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
          const SnackBar(content: Text('Biyometrik kilit açma etkinleştirildi')),
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
        const SnackBar(content: Text('Biyometri kilitlendi — sonra tekrar dene')),
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
    final enrolled = context
        .select<VaultLockCubit, bool>((c) => c.state.biometricEnrolled);
    final deviceAvailable = context
        .select<VaultLockCubit, bool>((c) => c.state.deviceBiometricAvailable);

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
            if (enrolled)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Biyometri yalnız bir kısayoldur; cihaz biyometri ayarların '
                  'değişirse otomatik geçersiz olur ve tekrar açman gerekir.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            _buildLiveSyncTile(context),
          ],
        ),
      ),
    );
  }

  /// Faz 3 Patch 3 — canlı senkron (Realtime) toggle'ı. Yalnız sync destekleniyorsa
  /// (uid'li vault + pref yüklendi) gösterilir. Kapalıyken bile açılışta catch-up sync olur.
  Widget _buildLiveSyncTile(BuildContext context) {
    // VaultCubit yoksa (örn. yalnız VaultLockCubit'li ekranlar) toggle gizli.
    VaultCubit? vault;
    try {
      vault = context.read<VaultCubit>();
    } catch (_) {
      vault = null;
    }
    final live = _liveSync;
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
