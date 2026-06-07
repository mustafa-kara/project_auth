/// Uygulama teması (Material 3, açık + koyu) — Design.md §3 tasarım dili.
///
/// Precision/Technical yön: güven-mavi + katmanlı koyu yüzeyler, Geist tipografisi
/// (kod/sayaç GeistMono + tabular). İki tema birlikte tasarlanır; semantic token'lar
/// (`ColorScheme` + `CountdownColors` extension). Raw hex bileşenlerde KULLANILMAZ.
library;

import 'package:flutter/material.dart';

import '../ui/tokens.dart';

abstract final class AppTheme {
  /// Güven-mavi seed (security utility). Önceki düz indigo #3D5AFE yerine.
  static const _seed = Color(0xFF2563EB); // blue-600

  static const _displayFont = 'Geist';
  static const monoFont = 'GeistMono';

  static ThemeData light() => _build(Brightness.light, CountdownColors.light);
  static ThemeData dark() => _build(Brightness.dark, CountdownColors.dark);

  static ThemeData _build(Brightness brightness, CountdownColors countdown) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      fontFamily: _displayFont,
    );

    return base.copyWith(
      extensions: [countdown],
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
    );
  }

  /// Geist tabanlı tip ölçeği; kod stilleri ayrı (GeistMono + tabular) — kullanım
  /// noktasında `monoCode`/`monoLabel` ile uygulanır.
  static TextTheme _textTheme(TextTheme base) => base.apply(
        fontFamily: _displayFont,
      );

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

  /// Recovery mnemonic kelimesi stili: GeistMono (Design.md §3.2 — "recovery
  /// kelimeleri"). Tabular değil (kelime, sayı değil) ama mono → tek tip, kopya
  /// kolay, yazım hatası ayırt edilir (l/1, O/0).
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
