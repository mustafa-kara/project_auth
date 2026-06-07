/// Tasarım token'ları (Design.md §3) — spacing, radius, motion + ColorScheme dışı
/// anlamsal renkler (sayaç durumları) `ThemeExtension` olarak.
library;

import 'package:flutter/material.dart';

/// 4/8dp spacing skalası.
abstract final class Gap {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// Köşe yarıçapı token'ları.
abstract final class Radii {
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
}

/// Motion süreleri (Design.md §3.3: 150–300ms, transform/opacity).
abstract final class Motion {
  static const fast = Duration(milliseconds: 150);
  static const normal = Duration(milliseconds: 220);
}

/// Sayaç (geri sayım) renk tonları — `ColorScheme`'de yok, ayrı semantic token.
/// Renk ASLA tek sinyal değil; sayı/şekil ile birlikte kullanılır (color-not-only).
@immutable
class CountdownColors extends ThemeExtension<CountdownColors> {
  /// Kalan süre bol.
  final Color healthy;

  /// Kalan süre azalıyor (son %33).
  final Color warning;

  /// Kritik (son [criticalSeconds] saniye).
  final Color critical;

  /// Kritik eşiği — MUTLAK saniye (Design.md §3: "<5sn"). Periyottan bağımsız;
  /// period=60'ta da, period=15'te de son 5 saniyede kritik (review P3 — eski
  /// `5/30` fraction'ı period≠30'da yanlış eşik üretiyordu).
  static const criticalSeconds = 5;

  const CountdownColors({
    required this.healthy,
    required this.warning,
    required this.critical,
  });

  /// Kalan saniye + periyot için renk seçer. Kritik MUTLAK saniyeyle (color-not-only
  /// olduğundan sayı zaten birlikte gösterilir).
  Color forRemaining(int remaining, int period) {
    if (remaining <= criticalSeconds) return critical;
    final p = period <= 0 ? 30 : period;
    if (remaining / p <= 1 / 3) return warning;
    return healthy;
  }

  @override
  CountdownColors copyWith({Color? healthy, Color? warning, Color? critical}) =>
      CountdownColors(
        healthy: healthy ?? this.healthy,
        warning: warning ?? this.warning,
        critical: critical ?? this.critical,
      );

  @override
  CountdownColors lerp(ThemeExtension<CountdownColors>? other, double t) {
    if (other is! CountdownColors) return this;
    return CountdownColors(
      healthy: Color.lerp(healthy, other.healthy, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      critical: Color.lerp(critical, other.critical, t)!,
    );
  }

  static const light = CountdownColors(
    healthy: Color(0xFF15803D), // green-700 (WCAG kontrast)
    warning: Color(0xFFB45309), // amber-700
    critical: Color(0xFFB91C1C), // red-700
  );

  static const dark = CountdownColors(
    healthy: Color(0xFF4ADE80), // green-400
    warning: Color(0xFFFBBF24), // amber-400
    critical: Color(0xFFF87171), // red-400
  );
}
