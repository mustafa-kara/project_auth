/// Açılış splash'i (Faz 3 Patch 1) — SessionStatus.unknown / VaultLock.restoring
/// boyunca gösterilir.
///
/// Bootstrap (Supabase oturum + vault kilit) tamamlanınca guard otomatik
/// yönlendirir. Vault `ShellRoute`'unun DIŞINDA (masterKey gerektirmez — reviewer [P1]).
/// Tasarım: merkez kilit glyph'i (primary, tek aksan) + wordmark + ince primary
/// spinner (splash.md §4); reduced-motion'da spinner statik.
library;

import 'package:flutter/material.dart';

import '../../../../core/ui/tokens.dart';

class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Semantics(
            label: 'Yükleniyor',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Marka işareti: kilit glyph'i, tek steel-blue aksan (gradyan/glow yok).
                Icon(Icons.lock_outline, size: 56, color: scheme.primary),
                const SizedBox(height: Gap.lg),
                Text(
                  'project_auth',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: scheme.onSurface),
                ),
                const SizedBox(height: Gap.xl),
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                    // reduced-motion: dönen yerine statik halka (splash.md §6).
                    value: reduceMotion ? 0.25 : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
