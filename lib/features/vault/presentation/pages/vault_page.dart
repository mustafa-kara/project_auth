/// Ana vault ekranı: kayıtlı OTP kodlarının listesi + arama + QR/manuel ekleme.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/di/locator.dart';
import '../../../../core/otp/otp_account.dart';
import '../../../../core/otp/otpauth_uri.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/app_banner.dart';
import '../../../../core/ui/widgets/auth_bits.dart';
import '../../../../core/ui/widgets/empty_state.dart';
import '../../../../core/ui/widgets/skeleton_loader.dart';
import '../../../../core/ui/widgets/staggered_entrance.dart';
import '../../../../core/ui/widgets/status_badge.dart';
import '../../../auth/presentation/bloc/vault_lock_cubit.dart';
import '../../data/view_mode_store.dart';
import '../../domain/token_sync_service.dart';
import '../bloc/vault_cubit.dart';
import '../widgets/otp_card.dart';

class VaultPage extends StatefulWidget {
  const VaultPage({super.key});

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  /// Kullanıcı bu oturumda corruption banner'ını "Yine de devam et" ile gizledi mi.
  /// (Bozuk kayıtlar korunur; banner yalnız görsel olarak kapanır.)
  bool _corruptionDismissed = false;

  /// Aktif uid namespace'li `ViewModeStore` (reviewer [P3] — per-uid kart/liste).
  /// ShellRoute `RepositoryProvider` ile sağlar; standalone (test) durumda global
  /// singleton'a düşer.
  late final ViewModeStore _viewModeStore;
  VaultViewMode _viewMode = VaultViewMode.card;

  @override
  void initState() {
    super.initState();
    _viewModeStore = _resolveViewModeStore();
    _viewModeStore.read().then((m) {
      if (mounted) setState(() => _viewMode = m);
    });
  }

  ViewModeStore _resolveViewModeStore() {
    try {
      return context.read<ViewModeStore>(); // ShellRoute (per-uid)
    } catch (_) {
      return locator<ViewModeStore>(); // fallback (standalone/test)
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggleViewMode() {
    final next =
        _viewMode == VaultViewMode.card ? VaultViewMode.list : VaultViewMode.card;
    setState(() => _viewMode = next);
    _viewModeStore.write(next); // tercih kalıcı
  }

  /// Bir cubit mutasyonunu çalıştırır; kalıcılık (save) hatası olursa kullanıcıya
  /// SnackBar gösterir. Bellek-içi state zaten güncellenmiştir (kullanıcı değişimi
  /// görür) ama yazma başarısız olduğu için bilgilendirme şart (sessiz kayıp olmasın).
  Future<void> _runMutation(Future<void> op, String errorPrefix) async {
    try {
      await op;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('$errorPrefix: $e')));
    }
  }

  /// Arama filtresi: issuer/account/label üzerinde case-insensitive, boşluk-dayanıklı.
  List<OtpAccount> _filter(List<OtpAccount> accounts) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return accounts;
    return accounts.where((a) {
      final hay = '${a.issuer ?? ''} ${a.accountName} ${a.label}'.toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    // Bütünlük hatası state'inde ekleme aksiyonlarını gizle: o state'te add/save
    // diskteki bozuk-ama-kurtarılabilir vault'u onaysız ezerdi (review P1). Cubit
    // de mutasyonu reddeder (asıl emniyet); bu FAB gizleme savunma katmanı.
    final state = context.watch<VaultCubit>().state;
    final integrityBlocked = state.loaded && state.error != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Authenticator'),
        actions: [
          _SyncIndicator(syncState: state.syncState),
          IconButton(
            icon: Icon(_viewMode == VaultViewMode.card
                ? Icons.view_list_outlined
                : Icons.grid_view_outlined),
            tooltip: _viewMode == VaultViewMode.card
                ? 'Kompakt liste görünümü'
                : 'Kart görünümü',
            onPressed: _toggleViewMode,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Ayarlar',
            onPressed: () => context.pushNamed('settings'),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Ara (issuer / hesap)',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: 'Aramayı temizle',
                        // Hem state'i hem görünen metni temizle (controller yoksa
                        // input eski metni gösterirdi ama liste filtresiz olurdu).
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
        ),
      ),
      body: BlocBuilder<VaultCubit, VaultState>(
        builder: (context, state) {
          if (!state.loaded) {
            // Loading iskeleti: success layout'unun hairline kopyası (CLS yok),
            // mevcut görünüm yoğunluğuyla (Design.md §14.12).
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              child: OtpListSkeleton(compact: _viewMode == VaultViewMode.list),
            );
          }
          // Bütünlük hatası (top-level bozulma / tüm kayıtlar decrypt fail) →
          // "boş vault" gibi gösterme; açık bütünlük ekranı (review #5).
          if (state.error != null) {
            return _IntegrityErrorView(error: state.error!);
          }
          if (state.accounts.isEmpty) {
            return EmptyState(
              icon: Icons.lock_outline,
              title: 'Henüz kod yok',
              description:
                  'QR kod tarayarak veya otpauth:// bağlantısını manuel ekleyerek başlayın.',
              actionLabel: 'Kod ekle',
              onAction: () => _showAddMenu(context),
              primaryAction: true,
            );
          }
          final visible = _filter(state.accounts);
          // Kısmi bozulma uyarı banner'ı (AppBanner, warning) — sağlam token'lar
          // yine de gösterilir (Design.md §11 dürüst hata, §14.10).
          final banner = (state.corruptedCount > 0 && !_corruptionDismissed)
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
                  child: AppBanner(
                    kind: StatusKind.warning,
                    icon: Icons.warning_amber,
                    message:
                        '${state.corruptedCount} kayıt çözülemedi. Sağlam kodların aşağıda.',
                    actions: [
                      BannerAction(
                        'Yine de devam et',
                        () => setState(() => _corruptionDismissed = true),
                      ),
                      BannerAction(
                        'Bozuk kayıtları kaldır',
                        () => _confirmPurge(context),
                        destructive: true,
                      ),
                    ],
                  ),
                )
              : null;
          final compact = _viewMode == VaultViewMode.list;
          final list = visible.isEmpty
              ? EmptyState(
                  icon: Icons.search_off,
                  title: 'Aramayla eşleşen kod yok',
                  description: '"$_query" için sonuç bulunamadı.',
                  actionLabel: 'Aramayı temizle',
                  onAction: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                      Gap.lg, Gap.sm, Gap.lg, 88), // FAB için alt boşluk
                  itemCount: visible.length,
                  itemBuilder: (context, i) {
                    final acc = visible[i];
                    // İlk girişte stagger fade+slide (Design.md §7, vault.md §6);
                    // reduced-motion'da kapalı. Stabil id key: silme/reorder/filtre
                    // sonrası Flutter State'i yanlış hesaba reuse edemez (aksi halde
                    // TOTP timer'ı durabilir).
                    return StaggeredEntrance(
                      key: ValueKey(acc.id),
                      index: i,
                      child: OtpCard(
                        account: acc,
                        compact: compact,
                        onIncrement: () => _runMutation(
                          context.read<VaultCubit>().incrementCounter(acc.id),
                          'Sayaç kaydedilemedi',
                        ),
                        onDelete: () => _runMutation(
                          context.read<VaultCubit>().removeById(acc.id),
                          'Silme kaydedilemedi',
                        ),
                      ),
                    );
                  },
                );
          if (banner == null) return list;
          return Column(
            children: [banner, Expanded(child: list)],
          );
        },
      ),
      floatingActionButton: integrityBlocked
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _showAddMenu(context),
              icon: const Icon(Icons.add),
              label: const Text('Ekle'),
            ),
    );
  }

  /// Ekleme yöntemini seçtirir: QR tara veya manuel `otpauth://`.
  void _showAddMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('QR kod tara'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                context.push(Routes.scan);
              },
            ),
            ListTile(
              leading: const Icon(Icons.keyboard),
              title: const Text('Manuel otpauth:// gir'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                _showManualSheet(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showManualSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => _AddSheet(cubit: context.read<VaultCubit>()),
    );
  }

  /// Bozuk kayıtları kaldır — açık onay (geri alınamaz). Onaysız asla silinmez.
  Future<void> _confirmPurge(BuildContext context) async {
    final cubit = context.read<VaultCubit>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Bozuk kayıtları kaldır?'),
        content: const Text(
            'Çözülemeyen kayıtlar KALICI silinir. Bu işlem geri alınamaz. '
            'Sağlam token\'lara dokunulmaz.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Kaldır'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _runMutation(cubit.purgeCorrupted(), 'Temizlenemedi');
    }
  }
}

/// Faz 3 Patch 3 — AppBar bulut senkron göstergesi. `syncing` → dönen ikon; `error`
/// → uyarı ikonu (tooltip); `malformedCount>0` → uyarı rozeti; `idle` & temiz → boş.
/// a11y: Semantics label. Sync desteklenmiyorsa (legacy/uid-siz) durum hep idle → boş.
class _SyncIndicator extends StatelessWidget {
  final SyncState syncState;
  const _SyncIndicator({required this.syncState});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (syncState.phase) {
      case SyncPhase.syncing:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Center(
            child: Semantics(
              label: 'Senkronize ediliyor',
              child: const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        );
      case SyncPhase.error:
        return IconButton(
          icon: Icon(Icons.sync_problem, color: scheme.error),
          tooltip: 'Senkron hatası — sonra tekrar denenecek',
          onPressed: () => context.read<VaultCubit>().syncNow(),
        );
      case SyncPhase.idle:
        if (syncState.malformedCount > 0) {
          // Sunucuda okunamayan kayıt sayısı — color-not-only rozet (ikon+sayı).
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
            child: Center(
              child: Tooltip(
                message:
                    '${syncState.malformedCount} kayıt sunucuda okunamadı (atlandı)',
                child: InkWell(
                  borderRadius: BorderRadius.circular(Radii.sm),
                  onTap: () => context.read<VaultCubit>().syncNow(),
                  child: StatusBadge(
                    kind: StatusKind.warning,
                    icon: Icons.sync_problem,
                    label: '${syncState.malformedCount}',
                  ),
                ),
              ),
            ),
          );
        }
        return const SizedBox.shrink();
    }
  }
}

/// Toptan bütünlük hatası — boş vault DEĞİL; nötr metin (review #3). Parola
/// hatası ima edilmez (o, KeyManager.unlock'ta yakalanır). Aksiyonlar: yeniden aç
/// (farklı recovery dene) ve son çare çift-onaylı sıfırla (review P2 #5).
class _IntegrityErrorView extends StatelessWidget {
  final Object error;
  const _IntegrityErrorView({required this.error});

  /// Son çare: tüm vault'u sıfırla (çift onaylı, geri alınamaz). AuthIntegrityPage
  /// ile aynı kalıp; `VaultStorageKeys.all` siler → setup'a döner.
  Future<void> _confirmReset(BuildContext context) async {
    final lock = context.read<VaultLockCubit>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Vault\'u sıfırla?'),
        content: const Text(
            'Tüm şifreli token\'lar ve anahtar verisi KALICI silinir. '
            'Bu işlem geri alınamaz. Recovery key\'in olsa bile bu cihazdaki '
            'veri gider.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sıfırla'),
          ),
        ],
      ),
    );
    if (confirmed == true) await lock.resetVault();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.report_gmailerrorred, size: 48, color: scheme.error),
            const SizedBox(height: Gap.lg),
            Text('Vault açılamadı',
                style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: Gap.sm),
            Text('Hiçbir kayıt doğrulanamadı.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
                textAlign: TextAlign.center),
            const SizedBox(height: Gap.xl),
            FilledButton(
              // Vault'u yeniden aç: kilitle → guard /unlock'a yönlendirir.
              onPressed: () => context.read<VaultLockCubit>().lock(),
              child: const Text('Vault\'u yeniden aç'),
            ),
            const SizedBox(height: Gap.md),
            OutlinedButton(
              onPressed: () => _confirmReset(context),
              child: const Text('Vault\'u sıfırla'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Manuel `otpauth://` yapıştırma ekleme formu.
class _AddSheet extends StatefulWidget {
  final VaultCubit cubit;
  const _AddSheet({required this.cubit});

  @override
  State<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<_AddSheet> {
  final _controller = TextEditingController();
  String? _error;

  bool _saving = false;

  Future<void> _submit() async {
    final OtpAccount account;
    try {
      account = OtpAuthUri.parse(_controller.text);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    await _addAndClose(account);
  }

  Future<void> _addDemo() => _addAndClose(OtpAccount(
        secret: 'JBSWY3DPEHPK3PXP',
        type: OtpType.totp,
        issuer: 'Demo',
        accountName: 'demo@example.com',
      ));

  /// Token'ı ekler ve KALICILIĞI bekler; yazma başarılıysa kapatır, hata olursa
  /// formu açık bırakıp hatayı gösterir (kullanıcı "eklendi" sanıp kaybetmesin).
  Future<void> _addAndClose(OtpAccount account) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.cubit.add(account);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = 'Kaydedilemedi: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.sm,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Kod ekle', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _controller,
            // TOTP secret'i otpauth:// içinde gizli sayılır → klavye öğrenme
            // sözlüğüne / öneri çubuğuna sızmasın (parola/recovery alanlarıyla
            // hizalı). visiblePassword: maskelemez ama autocorrect'i kapatır.
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            decoration: InputDecoration(
              labelText: 'otpauth:// bağlantısı',
              hintText: 'otpauth://totp/...',
              errorText: _error,
            ),
            maxLines: 2,
          ),
          const SizedBox(height: Gap.md),
          FilledButton(
            onPressed: _saving ? null : _submit,
            child: _saving ? const BtnSpinner() : const Text('Ekle'),
          ),
          TextButton(
            onPressed: _saving ? null : _addDemo,
            child: const Text('Demo kodu ekle'),
          ),
        ],
      ),
    );
  }
}
