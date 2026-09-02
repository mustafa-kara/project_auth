/// Uygulama teması (Material 3, koyu + açık) — Design.md §3–§7 "Vault / Cipher".
///
/// Dark-first. Yüzeyler ve `primary` M3 `fromSeed` algoritmasına bırakılmaz;
/// Design.md §3.1 grafit/mürekkep paletine **el ile** sabitlenir (`copyWith`).
/// `CountdownColors` + `AppSurfaces` `ThemeExtension`'ları semantic token sağlar.
/// Kod/sayaç/recovery GeistMono + tabular. Ham hex YALNIZ bu dosyada + tokens.dart'ta.
library;

import 'package:flutter/material.dart';

import '../ui/tokens.dart';

abstract final class AppTheme {
  /// Steel-blue seed (Design.md §3.1). Yüzeyler override edilir; seed yalnız
  /// türetilmeyen ikincil tonlar için taban.
  static const _seed = Color(0xFF2563EB); // blue-600

  static const _displayFont = 'Geist';
  static const monoFont = 'GeistMono';

  // ── Dark palet (Design.md §3.1, varsayılan) ──────────────────────────────
  static const _dCanvas = Color(0xFF0E1116); // surface (ekran zemini)
  static const _dSurface = Color(0xFF151921); // surfaceContainerLow (kart)
  static const _dSurfaceAlt = Color(0xFF1B212B); // surfaceContainer
  static const _dSurfaceHigh = Color(0xFF222A36); // surfaceContainerHigh
  static const _dBorder = Color(0xFF252C37); // outlineVariant (hairline)
  static const _dBorderStrong = Color(0xFF3A4452); // outline
  static const _dTextPrimary = Color(0xFFECEEF2); // onSurface
  static const _dTextSecondary = Color(0xFFA6AEBB); // onSurfaceVariant
  static const _dPrimary = Color(0xFF6AA4FF); // steel-blue (grafit üstü)
  static const _dOnPrimary = Color(0xFF0B1220); // koyu mürekkep (AA, §3.2)
  static const _dPrimaryContainer = Color(0xFF1E3252);
  static const _dCritical = Color(0xFFF87171);

  // ── Light palet (Design.md §3.1, bağımsız varyant) ───────────────────────
  static const _lCanvas = Color(0xFFFBFBFA);
  static const _lSurface = Color(0xFFFFFFFF);
  static const _lSurfaceAlt = Color(0xFFF2F3F5);
  static const _lSurfaceHigh = Color(0xFFE9EBEE);
  static const _lBorder = Color(0xFFE4E6EA);
  static const _lBorderStrong = Color(0xFFC7CBD2);
  static const _lTextPrimary = Color(0xFF13161B);
  static const _lTextSecondary = Color(0xFF525A66);
  static const _lPrimary = Color(0xFF2563EB);
  static const _lOnPrimary = Color(0xFFFFFFFF);
  static const _lPrimaryContainer = Color(0xFFDCE7FF);
  static const _lCritical = Color(0xFFB91C1C);

  static ThemeData light() =>
      _build(Brightness.light, CountdownColors.light, AppSurfaces.light);
  static ThemeData dark() =>
      _build(Brightness.dark, CountdownColors.dark, AppSurfaces.dark);

  static ThemeData _build(
    Brightness brightness,
    CountdownColors countdown,
    AppSurfaces surfaces,
  ) {
    final isDark = brightness == Brightness.dark;
    // M3 fromSeed taban → türetilmeyen tonlar (secondary/tertiary container vb.)
    // korunur; Design.md §3.1 token'ları el ile override edilir.
    final scheme =
        ColorScheme.fromSeed(seedColor: _seed, brightness: brightness).copyWith(
          surface: isDark ? _dCanvas : _lCanvas,
          surfaceContainerLowest: isDark ? _dCanvas : _lCanvas,
          surfaceContainerLow: isDark ? _dSurface : _lSurface,
          surfaceContainer: isDark ? _dSurfaceAlt : _lSurfaceAlt,
          surfaceContainerHigh: isDark ? _dSurfaceHigh : _lSurfaceHigh,
          surfaceContainerHighest: isDark ? _dSurfaceHigh : _lSurfaceHigh,
          outlineVariant: isDark ? _dBorder : _lBorder,
          outline: isDark ? _dBorderStrong : _lBorderStrong,
          onSurface: isDark ? _dTextPrimary : _lTextPrimary,
          onSurfaceVariant: isDark ? _dTextSecondary : _lTextSecondary,
          primary: isDark ? _dPrimary : _lPrimary,
          onPrimary: isDark ? _dOnPrimary : _lOnPrimary,
          primaryContainer: isDark ? _dPrimaryContainer : _lPrimaryContainer,
          onPrimaryContainer: isDark ? _dTextPrimary : _lTextPrimary,
          error: isDark ? _dCritical : _lCritical,
          onError: isDark ? _dOnPrimary : _lOnPrimary,
          scrim: const Color(0xFF000000),
        );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      fontFamily: _displayFont,
      scaffoldBackgroundColor: scheme.surface,
    );

    return base.copyWith(
      extensions: [countdown, surfaces],
      textTheme: _textTheme(base.textTheme),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        color: scheme.surfaceContainerLow,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48), // ≥44pt dokunma hedefi
          textStyle: const TextStyle(
            fontFamily: _displayFont,
            fontWeight: FontWeight.w500, // labelLarge (§5.2)
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        // Birincil aksiyon: steel-blue zemin + uygulamadaki en güçlü gölge
        // (Design.md §4 — FAB öne çıkar). M3 varsayılanı surfaceContainer'a
        // düşüyordu; primary'ye sabitlenir.
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 6,
        focusElevation: 6,
        hoverElevation: 8,
        highlightElevation: 8,
        extendedTextStyle: const TextStyle(
          fontFamily: _displayFont,
          fontWeight: FontWeight.w600,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          side: BorderSide(color: scheme.outline),
          textStyle: const TextStyle(
            fontFamily: _displayFont,
            fontWeight: FontWeight.w500,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: const TextStyle(
            fontFamily: _displayFont,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide(color: scheme.error),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: _displayFont,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.surfaceContainerHigh,
        contentTextStyle: TextStyle(
          fontFamily: _displayFont,
          color: scheme.onSurface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
    );
  }

  /// Geist tabanlı tip ölçeği (Design.md §5.2). Başlık/etiket weight'leri M3
  /// üstünde sabitlenir; kod stilleri ayrı (GeistMono + tabular).
  static TextTheme _textTheme(TextTheme base) {
    final t = base.apply(fontFamily: _displayFont);
    return t.copyWith(
      headlineSmall: t.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
      titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleLarge: t.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w500),
    );
  }

  /// OTP kodu stili: GeistMono + tabular figürler (her tikte layout kaymaz).
  static TextStyle monoCode(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextStyle(
      fontFamily: monoFont,
      fontSize: 30,
      fontWeight: FontWeight.w500,
      letterSpacing: 2,
      color: scheme.primary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  /// Kompakt liste kod stili (daha küçük).
  static TextStyle monoCodeCompact(BuildContext context) =>
      monoCode(context).copyWith(fontSize: 22);

  /// Recovery mnemonic kelimesi stili: GeistMono (Design.md §5.1). Tabular değil
  /// (kelime, sayı değil) ama mono → tek tip, kopya kolay, l/1·O/0 ayırt edilir.
  static TextStyle monoWord(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextStyle(
      fontFamily: monoFont,
      fontSize: 15,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.2,
      color: scheme.onSurface,
    );
  }
}
