/// `EmptyState` (Design.md §14.11) — boş/sonuç-yok durumu.
///
/// Ortalanmış: 64dp çizgisel ikon (`textTertiary`) → `titleMedium` başlık →
/// `bodyMedium` `textSecondary` açıklama → opsiyonel CTA. Metin ekrana özgü
/// olmalı (jenerik "veri yok" yasak). Hem boş vault, hem arama-sonuç-yok, hem
/// kamera-izni-yok gibi durumlarda kullanılır.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  /// Opsiyonel CTA — metin + geri çağrı. İkisi de verilirse buton çizilir.
  final String? actionLabel;
  final VoidCallback? onAction;

  /// CTA stili: true → `FilledButton` (birincil), false → `TextButton` (ghost).
  final bool primaryAction;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.actionLabel,
    this.onAction,
    this.primaryAction = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surfaces = AppSurfaces.of(context);
    final hasAction = actionLabel != null && onAction != null;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: surfaces.textTertiary),
            const SizedBox(height: Gap.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: Gap.sm),
            Text(
              description,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (hasAction) ...[
              const SizedBox(height: Gap.xl),
              if (primaryAction)
                FilledButton(onPressed: onAction, child: Text(actionLabel!))
              else
                TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
