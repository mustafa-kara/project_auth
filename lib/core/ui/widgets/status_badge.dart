/// `StatusBadge` (Design.md §14.9) — durum rozeti pill'i.
///
/// Daima **ikon + metin** (color-not-only, §12). Zemin = durum renginin %10–14'ü
/// (`AppSurfaces.successBg/warningBg/criticalBg`), metin/ikon = rengin kendisi.
/// Kullanım: biyometri "kullanılamıyor" (warning), sync "bayat"/"hata", "yeni"
/// duyuru (primary).
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

enum StatusKind { success, warning, critical, primary }

class StatusBadge extends StatelessWidget {
  final StatusKind kind;
  final IconData icon;
  final String label;

  const StatusBadge({
    super.key,
    required this.kind,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final countdown =
        theme.extension<CountdownColors>() ?? CountdownColors.dark;
    final surfaces = AppSurfaces.of(context);

    final (Color fg, Color bg) = switch (kind) {
      StatusKind.success => (countdown.healthy, surfaces.successBg),
      StatusKind.warning => (countdown.warning, surfaces.warningBg),
      StatusKind.critical => (scheme.error, surfaces.criticalBg),
      StatusKind.primary => (
          scheme.primary,
          scheme.primary.withValues(alpha: 0.12),
        ),
    };

    return Semantics(
      label: label,
      container: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.sm,
          vertical: Gap.xs,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: Gap.xs),
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
