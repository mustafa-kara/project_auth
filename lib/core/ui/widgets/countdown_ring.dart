/// Dairesel geri sayım halkası (Design.md §4) — değer = kalan/period, renk
/// yeşil→amber→kırmızı + ORTADA kalan saniye (renk asla tek sinyal değil).
///
/// <5sn'de hafif scale-pulse; reduced-motion'da animasyon kapanır ama renk + sayı
/// korunur (color-not-only + erişilebilirlik). Semantics etiketi sağlanır.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

class CountdownRing extends StatelessWidget {
  /// Kalan saniye.
  final int remaining;

  /// Periyot (sn) — 0'a karşı korunur.
  final int period;

  final double size;

  const CountdownRing({
    super.key,
    required this.remaining,
    required this.period,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    final p = period <= 0 ? 30 : period;
    final fraction = (remaining / p).clamp(0.0, 1.0);
    final countdown =
        Theme.of(context).extension<CountdownColors>() ?? CountdownColors.dark;
    final color = countdown.forRemaining(remaining, p);
    // Kritik = mutlak son 5sn (Design.md §3; periyottan bağımsız — review P3).
    final critical = remaining <= CountdownColors.criticalSeconds;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    final ring = SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: fraction,
            strokeWidth: 3,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
          Text(
            '$remaining',
            style: TextStyle(
              fontFamily: 'GeistMono',
              fontSize: size * 0.34,
              fontWeight: FontWeight.w500,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );

    final labeled = Semantics(
      label: '$remaining saniye kaldı',
      child: ExcludeSemantics(child: ring),
    );

    // <5sn pulse — yalnız reduced-motion kapalıyken.
    if (critical && !reduceMotion) {
      return _Pulse(child: labeled);
    }
    return labeled;
  }
}

/// 0.95↔1.05 arası nazik scale pulse (transform-only, interruptible).
class _Pulse extends StatefulWidget {
  final Widget child;
  const _Pulse({required this.child});

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.normal,
  )..repeat(reverse: true);
  late final Animation<double> _scale = Tween(
    begin: 0.95,
    end: 1.05,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ScaleTransition(scale: _scale, child: widget.child);
}
