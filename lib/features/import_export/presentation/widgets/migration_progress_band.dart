/// Google Authenticator aktarımının ilerleme bandı: kaç QR tarandı + üç çıkış
/// yolu (devam / bu kadar yeter / baştan başla).
///
/// Phase 5 Patch 3 W0 — moved out of `scan_page.dart` UNCHANGED (behaviour is
/// byte-for-byte the old private `_MigrationBand`). W3 reuses it in the pasted
/// migration-link flow inside `AddTokenSheet` (plan §5 D4), which is why it now
/// lives next to `ImportPreviewView` in the import/export widgets folder rather
/// than inside the scan page.
///
/// The two callers collect the same export by different means — one SCANS codes
/// with the camera, the other has links PASTED into it — so the two sentences
/// that name the thing being collected are parameters ([progressLabel],
/// [remainingHint]). Everything else, the counts included, is identical and
/// stays here: a band that says "2/3 kod tarandı" on one screen must not drift
/// into a different shape on the other.
///
/// SECURITY: shows COUNTS only — never an issuer, an account name or a secret.
library;

import 'package:flutter/material.dart';

import '../../../../core/ui/tokens.dart';

/// Migration modunun alt bandı: ilerleme + üç çıkış yolu.
class MigrationProgressBand extends StatelessWidget {
  const MigrationProgressBand({
    super.key,
    required this.scanned,
    required this.total,
    required this.complete,
    required this.onContinue,
    required this.onStopEarly,
    required this.onRestart,
    this.progressLabel = 'kod tarandı',
    this.remainingHint = 'Kalan kodları sırayla okut',
  });

  final int scanned;
  final int total;
  final bool complete;
  final VoidCallback onContinue;
  final VoidCallback onStopEarly;
  final VoidCallback onRestart;

  /// İlerleme satırının sayaçtan SONRAKİ kısmı: '2/3 [progressLabel]'.
  /// Varsayılan kamera taraması içindir; yapıştırma akışı 'bağlantı eklendi'
  /// geçer.
  final String progressLabel;

  /// Tamamlanmamışken gösterilen yönerge. Kamerada "okut", yapıştırmada
  /// "yapıştır" denir.
  final String remainingHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      // `bottomNavigationBar` gövdenin SafeArea'sının dışında → alt çentik
      // dolgusunu bant kendi üstlenir.
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('$scanned/$total $progressLabel',
                  style: theme.textTheme.titleMedium),
              if (!complete) ...[
                const SizedBox(height: Gap.xs),
                Text(
                  remainingHint,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: Gap.md),
              if (complete)
                FilledButton(onPressed: onContinue, child: const Text('Devam'))
              else
                OutlinedButton(
                  onPressed: onStopEarly,
                  child: const Text('Bu kadar yeter'),
                ),
              TextButton(
                onPressed: onRestart,
                child: const Text('Baştan başla'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
