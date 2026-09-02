/// Ana vault ekranı: kayıtlı OTP kodlarının listesi + arama + QR/manuel ekleme.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/di/locator.dart';
import '../../../../core/otp/otp_account.dart';
import '../../../../core/platform/secure_screen.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/app_banner.dart';
import '../../../../core/ui/widgets/empty_state.dart';
import '../../../../core/ui/widgets/skeleton_loader.dart';
import '../../../../core/ui/widgets/staggered_entrance.dart';
import '../../../../core/ui/widgets/status_badge.dart';
import '../../../auth/presentation/bloc/vault_lock_cubit.dart';
import '../../data/view_mode_store.dart';
import '../../domain/token_sync_service.dart';
import '../bloc/vault_cubit.dart';
import '../widgets/add_token_sheet.dart';
import '../widgets/edit_token_sheet.dart';
import '../widgets/otp_card.dart';
import '../widgets/tag_chips_bar.dart';
import '../widgets/tag_manager_sheet.dart';
import '../widgets/token_action_sheet.dart';

class VaultPage extends StatefulWidget {
  const VaultPage({super.key});

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  /// Phase 5 Patch 3 — active tag filter, or null for "all codes".
  ///
  /// Single selection and SESSION-SCOPED on purpose: a filter that survived a
  /// restart is the classic way a user concludes a token has disappeared.
  String? _selectedTag;

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

  /// Arama filtresi: issuer/account/label/etiket üzerinde case-insensitive,
  /// boşluk-dayanıklı. [tag] verilirse arama ile AND'lenir (tek etiket).
  ///
  /// The tag is an exact membership test, not a substring one: a chip is a
  /// deliberate pick, so "iş" must not also match "işlem".
  List<OtpAccount> _filter(List<OtpAccount> accounts, String? tag) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty && tag == null) return accounts;
    return accounts.where((a) {
      if (tag != null && !a.tags.contains(tag)) return false;
      if (q.isEmpty) return true;
      final hay =
          '${a.issuer ?? ''} ${a.accountName} ${a.label} ${a.tags.join(' ')}'
              .toLowerCase();
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
    final scaffold = Scaffold(
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
          final cubit = context.read<VaultCubit>();
          final tags = cubit.allTags;
          // A tag that no longer exists (renamed/deleted on another device, or
          // removed from the last token holding it) must not keep hiding codes:
          // the selection is validated against the live list on every build
          // instead of being repaired with a setState during build.
          final activeTag =
              (_selectedTag != null && tags.contains(_selectedTag))
                  ? _selectedTag
                  : null;
          // The field itself is cleared AFTER the frame — never during build,
          // which would be a setState inside build. Without this the stale name
          // lives on in state: it would come back the moment the tag reappears
          // (a sync pull, an undo of the rename) and silently re-hide codes the
          // user is currently looking at.
          if (_selectedTag != null && activeTag == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _selectedTag != null) {
                setState(() => _selectedTag = null);
              }
            });
          }
          final visible = _filter(state.accounts, activeTag);
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
          final chips = TagChipsBar(
            tags: tags,
            selected: activeTag,
            onSelected: (t) => setState(() => _selectedTag = t),
            onManage: () => _showTagManager(context),
          );
          final list = visible.isEmpty
              ? (activeTag != null
                  ? EmptyState(
                      icon: Icons.sell_outlined,
                      title: 'Bu etikette kod yok',
                      description:
                          '« $activeTag » etiketiyle eşleşen kod bulunamadı.',
                      actionLabel: 'Filtreyi temizle',
                      onAction: _clearFilters,
                    )
                  : EmptyState(
                      icon: Icons.search_off,
                      title: 'Aramayla eşleşen kod yok',
                      description: '"$_query" için sonuç bulunamadı.',
                      actionLabel: 'Aramayı temizle',
                      onAction: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                    ))
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
                        // Long press no longer deletes: it opens the action
                        // sheet, and EVERY delete path (sheet entry and the
                        // 'Sil' assistive action below) goes through
                        // _confirmDelete first (risk R10).
                        onLongPress: () => _showTokenActions(acc),
                        onEdit: () => _showEditSheet(acc),
                        onDelete: () => _confirmDelete(acc),
                      ),
                    );
                  },
                );
          return Column(
            children: [
              ?banner,
              chips,
              Expanded(child: list),
            ],
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

    // Live OTP codes are on screen → screenshot / screen-recording / recents
    // preview protection (same sensitive-screen treatment as the recovery and
    // master-password screens). Ref-counted scope: pushing /scan or /settings
    // keeps this page mounted (protection stays on), and a nested sensitive
    // screen closing above it no longer turns the protection off early.
    return SecureScreenScope(child: scaffold);
  }

  /// Arama + etiket filtresini birlikte temizler (boş-filtre CTA'sı).
  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _query = '';
      _selectedTag = null;
    });
  }

  /// Uzun basış → eylem sheet'i (Phase 5 Patch 3, plan §5 D2).
  ///
  /// Replaces the old "long press deletes immediately" behaviour: the delete
  /// entry lands on [_confirmDelete], so a mis-touch can no longer cost the
  /// user access to an account's 2FA (risk R10 — CHANGELOG'a girer).
  Future<void> _showTokenActions(OtpAccount account) async {
    final action = await TokenActionSheet.show(context, account: account);
    if (!mounted || action == null) return;
    switch (action) {
      case TokenAction.edit:
        _showEditSheet(account);
      case TokenAction.tags:
        _showEditSheet(account, focusTags: true);
      case TokenAction.delete:
        await _confirmDelete(account);
    }
  }

  /// Metadata düzenleme sheet'i. Secret ASLA gösterilmez/okunmaz.
  void _showEditSheet(OtpAccount account, {bool focusTags = false}) {
    final cubit = context.read<VaultCubit>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => EditTokenSheet(
        account: account,
        cubit: cubit,
        focusTags: focusTags,
      ),
    );
  }

  /// Etiket yöneticisi. Yeniden adlandırma/silme aktif filtreyi taşır/temizler.
  void _showTagManager(BuildContext context) {
    final cubit = context.read<VaultCubit>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => TagManagerSheet(
        cubit: cubit,
        onRenamed: (from, to) {
          if (mounted && _selectedTag == from) {
            setState(() => _selectedTag = to);
          }
        },
        onDeleted: (tag) {
          if (mounted && _selectedTag == tag) {
            setState(() => _selectedTag = null);
          }
        },
      ),
    );
  }

  /// Kod silme — açık onay (geri alınamaz). Onaysız silinen tek yol yoktur.
  Future<void> _confirmDelete(OtpAccount account) async {
    final cubit = context.read<VaultCubit>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kodu sil?'),
        content: Text('« ${account.label} » kalıcı olarak silinecek. '
            'Bu işlem geri alınamaz — bu hesabın 2FA\'sına erişimini '
            'kaybedebilirsin.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _runMutation(cubit.removeById(account.id), 'Silme kaydedilemedi');
    }
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
            // Faz 5 Patch 1 — toplu aktarım da bir "ekleme" yolu; kullanıcı onu
            // Ayarlar'da aramak zorunda kalmasın (plan §5).
            ListTile(
              leading: const Icon(Icons.file_download_outlined),
              title: const Text('Başka uygulamadan içe aktar'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                context.push(Routes.importData);
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
      builder: (sheetCtx) => AddTokenSheet(cubit: context.read<VaultCubit>()),
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
