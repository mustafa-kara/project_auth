/// `StaggeredEntrance` (Design.md §7) — liste/grid girişinde tek-sefer stagger.
///
/// İlk birkaç öğe sıraya göre gecikmeli olarak 12px aşağıdan fade+slide ile gelir
/// (yalnız transform/opacity → CLS yok). Yalnızca **bir kez** oynar (ekran ilk
/// boyamasında); sonraki rebuild'lerde anında görünür. reduced-motion'da animasyon
/// tamamen kapanır (içerik anında, tam opak).
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

/// Stagger uygulanacak ilk öğe sayısı (Design.md §7 — "ilk ~8"). Gerisi anında.
const int kStaggerMaxItems = 8;

/// Öğeler arası gecikme (Design.md §7 — "30ms arayla").
const Duration kStaggerStep = Duration(milliseconds: 30);

class StaggeredEntrance extends StatefulWidget {
  /// Liste içindeki sıra (gecikme = index * step; `kStaggerMaxItems` üstü anında).
  final int index;
  final Widget child;

  const StaggeredEntrance({
    super.key,
    required this.index,
    required this.child,
  });

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.normal,
  );

  bool _started = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;

    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // reduced-motion veya stagger penceresi dışı → anında tam görünür.
    if (reduceMotion || widget.index >= kStaggerMaxItems) {
      _c.value = 1;
      return;
    }
    // index'e göre gecikmeli tek-sefer giriş.
    Future<void>.delayed(kStaggerStep * widget.index, () {
      if (mounted) _c.forward();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final t = Curves.easeOut.transform(_c.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 12), // 12px aşağıdan
            child: child,
          ),
        );
      },
    );
  }
}
