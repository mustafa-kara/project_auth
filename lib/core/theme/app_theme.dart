/// Uygulama teması (Material 3, açık + koyu).
library;

import 'package:flutter/material.dart';

abstract final class AppTheme {
  static const _seed = Color(0xFF3D5AFE);

  static ThemeData light() => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: _seed),
        brightness: Brightness.light,
      );

  static ThemeData dark() => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ),
        brightness: Brightness.dark,
      );
}
