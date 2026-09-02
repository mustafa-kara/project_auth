/// Shared import confirmation view: counts, the skipped-entry audit list and the
/// confirm button (plan §5).
///
/// Filled by W2, who moves `import_page.dart`'s `_buildPreview`/`_countLine`
/// here verbatim — the two entry points (file import and Google Authenticator
/// QR scan) must show identical wording, and the existing `import_page_test`
/// expectations are the contract for that wording.
///
/// Stateless and service-free: it renders an [ImportPreview] and calls back.
/// Applying the import stays with the caller, so nothing here can write to the
/// vault.
///
/// SECURITY: only `SkippedEntry.label`/`detail` and counts are rendered. No
/// secret reaches this widget tree; the caller is responsible for wrapping the
/// screen in `SecureScreenScope`.
library;

import 'package:flutter/material.dart';

import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/auth_bits.dart';
import '../../../../core/ui/widgets/status_badge.dart';
import '../../domain/import_models.dart';
import '../../domain/import_service.dart';

/// Bir girdinin neden atlandığının Türkçe açıklaması.
///
/// Lives here rather than in `import_page.dart` because it is only ever needed
/// to render this view, which both entry points (file import, Google
/// Authenticator scan) share.
String skipReasonLabel(SkipReason reason) => switch (reason) {
  SkipReason.unsupportedType => 'Desteklenmeyen token türü',
  SkipReason.invalidSecret => 'Secret okunamadı',
  SkipReason.invalidFields => 'Alanlar geçersiz',
  SkipReason.duplicateInFile => 'Dosyada tekrar ediyor',
  SkipReason.alreadyInVault => 'Zaten vault\'unda var',
};

class ImportPreviewView extends StatelessWidget {
  const ImportPreviewView({
    super.key,
    required this.preview,
    required this.onConfirm,
    required this.headerLabel,
    this.headerDetail,
    this.error,
    this.busy = false,
    this.confirmLabel = 'İçe aktar',
  });

  /// What would be added and what would not.
  final ImportPreview preview;

  /// Invoked when the user confirms. Disabled while [busy] or when
  /// `preview.toAdd` is empty.
  final VoidCallback onConfirm;

  /// Badge text naming the source, e.g. `importSourceLabel(source)` for a file
  /// or 'Google Authenticator' for a scan.
  final String headerLabel;

  /// Secondary header line: the file name, or '{i}/{n} kod' for a scan. Hidden
  /// when null.
  final String? headerDetail;

  /// Turkish error text shown above the confirm button; null hides it.
  final String? error;

  /// True while the confirmed import is being applied.
  final bool busy;

  /// Confirm button label; overridden only when a flow needs different wording.
  final String confirmLabel;

  /// How many skipped entries the audit list renders at most.
  ///
  /// The list is EAGER (an [ExpansionTile]'s children are all built when it
  /// expands), and the import path admits up to 1024 entries, so an unbounded
  /// list would build a thousand [ListTile]s in one frame on a phone. The
  /// remainder is summarised by a count instead: the list is an audit aid, not
  /// something anyone reads to the end — and the counts above it are already
  /// the authoritative totals.
  static const int maxSkippedShown = 50;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(Gap.lg),
            children: [
              Row(
                children: [
                  StatusBadge(
                    kind: StatusKind.primary,
                    icon: Icons.description_outlined,
                    label: headerLabel,
                  ),
                  if (headerDetail != null) ...[
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: Text(
                        headerDetail!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: Gap.lg),
              _countLine(
                context,
                Icons.add_circle_outline,
                '${preview.addCount} token içe aktarılacak',
                emphasis: true,
              ),
              _countLine(
                context,
                Icons.copy_all_outlined,
                '${preview.duplicateCount} zaten var',
              ),
              _countLine(
                context,
                Icons.block_outlined,
                '${preview.skippedCount} desteklenmiyor',
              ),
              if (preview.skipped.isNotEmpty) ...[
                const SizedBox(height: Gap.md),
                _skippedTile(context),
              ],
              if (error != null) ...[
                const SizedBox(height: Gap.md),
                AuthErrorText(error!),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: FilledButton(
            onPressed: busy || preview.toAdd.isEmpty ? null : onConfirm,
            child: busy ? const BtnSpinner() : Text(confirmLabel),
          ),
        ),
      ],
    );
  }

  /// Atlanan girdilerin denetim listesi — en çok [maxSkippedShown] satır.
  Widget _skippedTile(BuildContext context) {
    final total = preview.skipped.length;
    final shown = total < maxSkippedShown ? total : maxSkippedShown;
    final rest = total - shown;
    return ExpansionTile(
      title: Text('Atlananlar ($total)'),
      childrenPadding: const EdgeInsets.only(left: Gap.sm, right: Gap.sm),
      children: [
        for (final s in preview.skipped.take(shown))
          ListTile(
            dense: true,
            leading: const Icon(Icons.remove_circle_outline),
            title: Text(s.label ?? '(isimsiz)'),
            subtitle: Text(
              s.detail == null
                  ? skipReasonLabel(s.reason)
                  : '${skipReasonLabel(s.reason)} — ${s.detail}',
            ),
          ),
        if (rest > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.md),
            child: Text(
              '+$rest tane daha',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  Widget _countLine(
    BuildContext context,
    IconData icon,
    String text, {
    bool emphasis = false,
  }) {
    final theme = Theme.of(context);
    final color = emphasis
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              text,
              style:
                  (emphasis
                          ? theme.textTheme.titleMedium
                          : theme.textTheme.bodyMedium)
                      ?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
