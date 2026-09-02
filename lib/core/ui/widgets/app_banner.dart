/// `AppBanner` (Design.md §14.10) — uyarı/corruption banner'ı.
///
/// `surfaceAlt` (surfaceContainer) zemin + sol durum ikonu + metin + aksiyon
/// butonları. Dürüst hata (§11): bozulma sessizce yutulmaz; sağlıklı içerik
/// listede kalırken banner kullanıcıyı bilgilendirir. Renk asla tek kanal —
/// ikon + metin birlikte (§12).
library;

import 'package:flutter/material.dart';

import '../tokens.dart';
import 'status_badge.dart' show StatusKind;

/// Banner aksiyonu (etiket + geri çağrı + yıkıcı mı).
class BannerAction {
  final String label;
  final VoidCallback onPressed;
  final bool destructive;

  const BannerAction(this.label, this.onPressed, {this.destructive = false});
}

class AppBanner extends StatelessWidget {
  final StatusKind kind;
  final IconData icon;
  final String message;
  final List<BannerAction> actions;

  const AppBanner({
    super.key,
    required this.kind,
    required this.icon,
    required this.message,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final countdown =
        theme.extension<CountdownColors>() ?? CountdownColors.dark;

    final Color accent = switch (kind) {
      StatusKind.success => countdown.healthy,
      StatusKind.warning => countdown.warning,
      StatusKind.critical => scheme.error,
      StatusKind.primary => scheme.primary,
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: accent),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: Gap.xs,
              children: [
                for (final a in actions)
                  TextButton(
                    onPressed: a.onPressed,
                    style: TextButton.styleFrom(
                      foregroundColor: a.destructive
                          ? scheme.error
                          : scheme.primary,
                    ),
                    child: Text(a.label),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
