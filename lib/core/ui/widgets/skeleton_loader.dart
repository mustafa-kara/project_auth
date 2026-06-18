/// `SkeletonLoader` (Design.md §14.12) — yükleniyor iskeleti.
///
/// Success layout'unun hairline kopyası: öğe sayısı/boyut birebir → CLS yok.
/// Shimmer 1.2s `skeleton` gradyanı (`AppSurfaces.skeletonBase/Highlight`);
/// reduced-motion'da statik (animasyon kapanır, iskelet kalır — §7/§12).
/// `OtpCard` skeleton'u kart oranını (spacious/kompakt) korur.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

/// OtpCard liste iskeleti — vault loading state'i (Design.md §14.1 layout'u).
class OtpListSkeleton extends StatelessWidget {
  final int itemCount;
  final bool compact;

  const OtpListSkeleton({super.key, this.itemCount = 6, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return _Shimmer(
      child: ListView.separated(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        itemCount: itemCount,
        separatorBuilder: (_, _) => const SizedBox(height: Gap.md),
        itemBuilder: (_, _) => _OtpCardSkeleton(compact: compact),
      ),
    );
  }
}

class _OtpCardSkeleton extends StatelessWidget {
  final bool compact;
  const _OtpCardSkeleton({required this.compact});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avatar = compact ? 36.0 : 44.0;
    final ring = compact ? 36.0 : 40.0;
    final vGap = compact ? Gap.sm : Gap.md;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: EdgeInsets.symmetric(horizontal: Gap.lg, vertical: vGap),
      child: Row(
        children: [
          _Block(width: avatar, height: avatar, radius: avatar * 0.25),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Block(width: 96, height: 12, radius: Radii.sm),
                const SizedBox(height: Gap.sm),
                _Block(
                  width: compact ? 110 : 140,
                  height: compact ? 18 : 24,
                  radius: Radii.sm,
                ),
              ],
            ),
          ),
          const SizedBox(width: Gap.md),
          _Block(width: ring, height: ring, radius: ring / 2),
        ],
      ),
    );
  }
}

/// Tek skeleton bloğu — `skeleton` gradyan tonu (shimmer ata tarafından sürülür).
class _Block extends StatelessWidget {
  final double width;
  final double height;
  final double radius;
  const _Block({
    required this.width,
    required this.height,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: surfaces.skeletonBase,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Çocuk ağacın üstüne kayan shimmer gradyanı (transform-only). reduced-motion'da
/// statik döner.
class _Shimmer extends StatefulWidget {
  final Widget child;
  const _Shimmer({required this.child});

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      if (_c.isAnimating) _c.stop();
      return ExcludeSemantics(child: widget.child);
    }
    if (!_c.isAnimating) _c.repeat();

    final surfaces = AppSurfaces.of(context);
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (context, child) {
          return ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (bounds) {
              final dx = bounds.width * (2 * _c.value - 1);
              return LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  surfaces.skeletonBase,
                  surfaces.skeletonHighlight,
                  surfaces.skeletonBase,
                ],
                stops: const [0.35, 0.5, 0.65],
                transform: _SlideGradient(dx),
              ).createShader(bounds);
            },
            child: child,
          );
        },
      ),
    );
  }
}

/// Gradyanı yatay kaydıran transform (shimmer süpürmesi).
class _SlideGradient extends GradientTransform {
  final double dx;
  const _SlideGradient(this.dx);

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(dx, 0, 0);
}
