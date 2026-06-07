/// Servis logosu / fallback avatar (Design.md §3, §4).
///
/// Issuer adı slug'a normalize edilir; gömülü simple-icons (CC0) setinde eşleşme
/// varsa SVG (tema rengiyle boyanmış) gösterilir; yoksa **baş harf + isimden
/// deterministik türetilen renkli daire**. Runtime logo çekme YOK (offline/gizlilik).
library;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class IssuerAvatar extends StatelessWidget {
  /// Issuer (servis) adı — null/boş ise accountName baş harfi kullanılır.
  final String? issuer;

  /// Issuer boşsa fallback harfi için kullanılacak ad (örn. accountName).
  final String fallbackLabel;

  final double size;

  const IssuerAvatar({
    super.key,
    required this.issuer,
    required this.fallbackLabel,
    this.size = 40,
  });

  /// Gömülü simple-icons slug'ları (assets/icons/*.svg ile birebir).
  static const _availableSlugs = {
    'auth0', 'binance', 'bitbucket', 'bitwarden', 'cloudflare', 'coinbase',
    'digitalocean', 'discord', 'docker', 'dropbox', 'facebook', 'github',
    'gitlab', 'google', 'instagram', 'netlify', 'notion', 'npm', 'okta',
    'paypal', 'proton', 'reddit', 'steam', 'stripe', 'twitch', 'vercel', 'x',
  };

  /// Issuer adını simple-icons slug'ına normalize eder (lowercase, alfanümerik dışı temizle).
  static String slugFor(String name) =>
      name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  @override
  Widget build(BuildContext context) {
    final name = (issuer ?? '').trim();
    if (name.isNotEmpty) {
      final slug = slugFor(name);
      if (_availableSlugs.contains(slug)) {
        return _IconTile(slug: slug, size: size);
      }
    }
    return _InitialAvatar(
      label: name.isNotEmpty ? name : fallbackLabel,
      size: size,
    );
  }
}

class _IconTile extends StatelessWidget {
  final String slug;
  final double size;
  const _IconTile({required this.slug, required this.size});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(size * 0.25),
      ),
      padding: EdgeInsets.all(size * 0.22),
      child: SvgPicture.asset(
        'assets/icons/$slug.svg',
        colorFilter: ColorFilter.mode(scheme.onSurface, BlendMode.srcIn),
      ),
    );
  }
}

class _InitialAvatar extends StatelessWidget {
  final String label;
  final double size;
  const _InitialAvatar({required this.label, required this.size});

  // Deterministik palet — issuer string hash → indeks (tutarlı renk).
  static const _palette = [
    Color(0xFF2563EB), Color(0xFF7C3AED), Color(0xFFDB2777), Color(0xFF059669),
    Color(0xFFD97706), Color(0xFF0891B2), Color(0xFFDC2626), Color(0xFF4F46E5),
  ];

  Color get _color {
    var h = 0;
    for (final c in label.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return _palette[h % _palette.length];
  }

  String get _initial {
    final t = label.trim();
    return t.isEmpty ? '?' : t.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final color = _color;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        shape: BoxShape.circle,
      ),
      child: Text(
        _initial,
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
