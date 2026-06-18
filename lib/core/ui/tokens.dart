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

/// Motion süreleri (Design.md §7: 150–300ms, transform/opacity).
abstract final class Motion {
  static const fast = Duration(milliseconds: 150);
  static const normal = Duration(milliseconds: 220);

  /// Sheet açılış / route geçişi (Design.md §7 — "slow ~300ms").
  static const slow = Duration(milliseconds: 300);
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

/// `ColorScheme`'de doğrudan karşılığı olmayan Vault/Cipher semantic renkleri
/// (Design.md §3.1). Yüzey katmanları (`canvas`/`surface`/`surfaceAlt`/`surfaceHigh`)
/// `ColorScheme` üstünden okunur (app_theme.dart override'ı); burada yalnız M3'te
/// yeri olmayanlar: durum-zemin tonları, üçüncül metin, skeleton gradyanı, avatar
/// fallback paleti. Tüm değerler Design.md §3.1 tablosuyla birebir.
@immutable
class AppSurfaces extends ThemeExtension<AppSurfaces> {
  /// Üçüncül metin — yalnız tamamlayıcı/caption (Design.md §3.2: küçük birincil
  /// metinde kullanılmaz).
  final Color textTertiary;

  /// Başarı rozet/banner zemini (rengin %10–12'si).
  final Color successBg;

  /// Uyarı rozet/banner zemini (rengin %10–14'ü).
  final Color warningBg;

  /// Hata rozet/banner zemini (rengin %10–14'ü).
  final Color criticalBg;

  /// Shimmer gradyan başlangıcı (skeleton).
  final Color skeletonBase;

  /// Shimmer gradyan vurgusu (skeleton).
  final Color skeletonHighlight;

  /// Issuer baş-harf fallback avatar paleti — deterministik (hash) seçim
  /// (Design.md §14.3). 8 renk.
  final List<Color> avatarPalette;

  const AppSurfaces({
    required this.textTertiary,
    required this.successBg,
    required this.warningBg,
    required this.criticalBg,
    required this.skeletonBase,
    required this.skeletonHighlight,
    required this.avatarPalette,
  });

  /// Temadan okur; extension kayıtlı değilse (örn. ham `MaterialApp` / test)
  /// parlaklığa göre güvenli varsayılana düşer — bileşenler her ortamda çalışır
  /// (`CountdownColors.forRemaining` fallback'iyle aynı kalıp).
  static AppSurfaces of(BuildContext context) {
    final ext = Theme.of(context).extension<AppSurfaces>();
    if (ext != null) return ext;
    return Theme.of(context).brightness == Brightness.light ? light : dark;
  }

  @override
  AppSurfaces copyWith({
    Color? textTertiary,
    Color? successBg,
    Color? warningBg,
    Color? criticalBg,
    Color? skeletonBase,
    Color? skeletonHighlight,
    List<Color>? avatarPalette,
  }) =>
      AppSurfaces(
        textTertiary: textTertiary ?? this.textTertiary,
        successBg: successBg ?? this.successBg,
        warningBg: warningBg ?? this.warningBg,
        criticalBg: criticalBg ?? this.criticalBg,
        skeletonBase: skeletonBase ?? this.skeletonBase,
        skeletonHighlight: skeletonHighlight ?? this.skeletonHighlight,
        avatarPalette: avatarPalette ?? this.avatarPalette,
      );

  @override
  AppSurfaces lerp(ThemeExtension<AppSurfaces>? other, double t) {
    if (other is! AppSurfaces) return this;
    return AppSurfaces(
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      successBg: Color.lerp(successBg, other.successBg, t)!,
      warningBg: Color.lerp(warningBg, other.warningBg, t)!,
      criticalBg: Color.lerp(criticalBg, other.criticalBg, t)!,
      skeletonBase: Color.lerp(skeletonBase, other.skeletonBase, t)!,
      skeletonHighlight:
          Color.lerp(skeletonHighlight, other.skeletonHighlight, t)!,
      avatarPalette: [
        for (var i = 0; i < avatarPalette.length; i++)
          Color.lerp(avatarPalette[i], other.avatarPalette[i], t)!,
      ],
    );
  }

  /// Dark (varsayılan) — Design.md §3.1.
  static const dark = AppSurfaces(
    textTertiary: Color(0xFF6B7480),
    successBg: Color(0x1F4ADE80), // #4ADE80 @ %12
    warningBg: Color(0x24FBBF24), // #FBBF24 @ %14
    criticalBg: Color(0x24F87171), // #F87171 @ %14
    skeletonBase: Color(0xFF1B212B), // surfaceAlt
    skeletonHighlight: Color(0xFF222A36), // surfaceHigh
    avatarPalette: _avatarDark,
  );

  /// Light — Design.md §3.1 (bağımsız varyant, ters çevirme değil).
  static const light = AppSurfaces(
    textTertiary: Color(0xFF8A929E),
    successBg: Color(0x1A15803D), // #15803D @ %10
    warningBg: Color(0x1AB45309), // #B45309 @ %10
    criticalBg: Color(0x1AB91C1C), // #B91C1C @ %10
    skeletonBase: Color(0xFFF2F3F5),
    skeletonHighlight: Color(0xFFE9EBEE),
    avatarPalette: _avatarLight,
  );

  // Avatar fallback paleti (Design.md §14.3 "deterministik palet, 8 renk").
  // Issuer baş-harfi zemininde %18 alfa ile kullanılır; tam-doygun tonlar.
  static const _avatarDark = [
    Color(0xFF6AA4FF), // steel-blue (primary ailesi)
    Color(0xFF4ADE80), // green
    Color(0xFFFBBF24), // amber
    Color(0xFFF87171), // red
    Color(0xFFA78BFA), // violet
    Color(0xFF38BDF8), // sky
    Color(0xFFFB923C), // orange
    Color(0xFF2DD4BF), // teal
  ];

  static const _avatarLight = [
    Color(0xFF2563EB),
    Color(0xFF15803D),
    Color(0xFFB45309),
    Color(0xFFB91C1C),
    Color(0xFF7C3AED),
    Color(0xFF0284C7),
    Color(0xFFC2410C),
    Color(0xFF0F766E),
  ];
}
