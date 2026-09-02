/// Recovery key (24 kelime) gösterim grid'i — Design.md §3.2 (Geist Mono).
///
/// 24 kelime **2 sütun × 12 satır** numaralı düzende: tümü tek ekranda görünür
/// (uzun dikey liste DEĞİL → kullanıcı hepsini görmeden "yazdım" diye ilerleyemez).
/// Her hücre: sıra no (onSurfaceVariant) + kelime (GeistMono). Soldan sağa değil,
/// SÜTUN-ÖNCELİKLİ sıralama (sol sütun 1–12, sağ sütun 13–24) → okuma/yazma sırası
/// doğal. Kart yüzeyine alınır (surfaceContainer), seçilebilir metin.
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../tokens.dart';

class MnemonicGrid extends StatelessWidget {
  final List<String> words;

  const MnemonicGrid({super.key, required this.words});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final half = (words.length + 1) ~/ 2; // sol sütun kelime sayısı (12)
    final numberStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    Widget cell(int index) {
      if (index >= words.length) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            SizedBox(
              width: 28,
              child: Text('${index + 1}.', style: numberStyle),
            ),
            const SizedBox(width: Gap.xs),
            Expanded(
              // SelectableText: kullanıcı tek tek kelimeleri seçip kopyalayabilir
              // (Design.md §3.2). Büyük textScaler'da kelime sarılır, taşmaz.
              child: SelectableText(
                words[index],
                style: AppTheme.monoWord(context),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sol sütun: 1..half
          Expanded(
            child: Column(children: [for (var i = 0; i < half; i++) cell(i)]),
          ),
          const SizedBox(width: Gap.lg),
          // Sağ sütun: half..end
          Expanded(
            child: Column(
              children: [for (var i = half; i < half * 2; i++) cell(i)],
            ),
          ),
        ],
      ),
    );
  }
}
