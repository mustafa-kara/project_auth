/// Etiket yöneticisi — etiketleri yeniden adlandır / kaldır.
///
/// Phase 5 Patch 3 (plan §5 D3). Both operations touch EVERY token carrying the
/// tag, so both say up front how many codes they affect, and the delete dialog
/// spells out that only the LABEL goes away — no token is ever removed here.
///
/// The sheet rebuilds from the cubit's state (`allTags` is a pure derivation),
/// so a rename or a delete refreshes the list without any local bookkeeping.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/otp/otp_account.dart';
import '../../../../core/ui/tokens.dart';
import '../bloc/vault_cubit.dart';

class TagManagerSheet extends StatefulWidget {
  final VaultCubit cubit;

  /// Fired after a successful rename with the OLD and the NORMALIZED NEW name,
  /// so the vault page can carry an active filter over to the new label instead
  /// of silently dropping it.
  final void Function(String from, String to)? onRenamed;

  /// Fired after a successful delete so an active filter on that tag clears.
  final void Function(String tag)? onDeleted;

  const TagManagerSheet({
    super.key,
    required this.cubit,
    this.onRenamed,
    this.onDeleted,
  });

  @override
  State<TagManagerSheet> createState() => _TagManagerSheetState();
}

class _TagManagerSheetState extends State<TagManagerSheet> {
  /// How many accounts carry [tag] right now.
  int _countFor(String tag) =>
      widget.cubit.state.accounts.where((a) => a.tags.contains(tag)).length;

  void _report(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _rename(String tag, int count) async {
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => _RenameTagDialog(tag: tag),
    );
    if (raw == null) return;
    // Normalize with the model's own rules so the name reported back is the one
    // the vault will actually hold (trimmed, clipped) — otherwise a filter
    // carried over to an un-normalized name would match nothing.
    final normalized = OtpAccount.normalizeTags([raw]);
    if (normalized.isEmpty || normalized.first == tag) return; // no-op
    final to = normalized.first;
    try {
      await widget.cubit.renameTag(tag, to);
      widget.onRenamed?.call(tag, to);
      _report('$count kod güncellendi');
    } catch (e) {
      _report('Kaydedilemedi: $e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _delete(String tag, int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Etiketi sil?'),
        content: Text(
          '« $tag » etiketi $count koddan kaldırılacak. '
          'Kodların kendisi SİLİNMEZ.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Kaldır'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.cubit.deleteTag(tag);
      widget.onDeleted?.call(tag);
      _report('$count kod güncellendi');
    } catch (e) {
      _report('Kaydedilemedi: $e');
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: BlocBuilder<VaultCubit, VaultState>(
        bloc: widget.cubit,
        builder: (context, _) {
          final tags = widget.cubit.allTags;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Gap.lg,
                  Gap.lg,
                  Gap.lg,
                  Gap.sm,
                ),
                child: Text(
                  'Etiketleri yönet',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (tags.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Gap.lg,
                    Gap.sm,
                    Gap.lg,
                    Gap.xl,
                  ),
                  child: Text(
                    'Hiç etiket yok.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: tags.length,
                    itemBuilder: (context, i) {
                      final tag = tags[i];
                      final count = _countFor(tag);
                      return ListTile(
                        title: Text('$tag · $count kod'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              tooltip: 'Etiketi yeniden adlandır',
                              onPressed: () => _rename(tag, count),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'Etiketi sil',
                              onPressed: () => _delete(tag, count),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: Gap.sm),
            ],
          );
        },
      ),
    );
  }
}

/// "Etiketi yeniden adlandır" diyaloğu.
///
/// Its own widget so the [TextEditingController] lives exactly as long as the
/// dialog route: disposing it right after `showDialog` returns tore it down
/// while the dialog was still animating out ("used after being disposed").
class _RenameTagDialog extends StatefulWidget {
  final String tag;
  const _RenameTagDialog({required this.tag});

  @override
  State<_RenameTagDialog> createState() => _RenameTagDialogState();
}

class _RenameTagDialogState extends State<_RenameTagDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.tag,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Etiketi yeniden adlandır'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: OtpAccount.maxTagRunes,
      decoration: const InputDecoration(labelText: 'Yeni ad'),
      onSubmitted: (v) => Navigator.of(context).pop(v),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Vazgeç'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_controller.text),
        child: const Text('Kaydet'),
      ),
    ],
  );
}
