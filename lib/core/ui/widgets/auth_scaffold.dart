/// Auth akışı ekranları için ortak iskelet (Design.md §3/§4 tasarım dili).
///
/// Tüm setup/unlock/recovery/integrity ekranları aynı ritmi paylaşır: ikon +
/// başlık (headlineSmall) + açıklama (bodyMedium/onSurfaceVariant) + gövde +
/// sabit alt aksiyon alanı. Tutarlı `Gap` spacing, safe area, kaydırılabilir
/// gövde (dynamic type / küçük ekranda taşma yok — Design.md erişilebilirlik).
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

class AuthScaffold extends StatelessWidget {
  /// AppBar başlığı (kısa). null ise AppBar gösterilmez.
  final String? appBarTitle;

  /// Geri/kapat aksiyonu (AppBar leading). null ise leading yok.
  final Widget? leading;

  /// Üstte gösterilen büyük ikon (örn. kilit). null ise ikon yok.
  final IconData? icon;

  /// Ikon rengi (varsayılan primary). Hata ekranlarında error verilebilir.
  final Color? iconColor;

  /// Başlık (headlineSmall, Geist). Ekranın ana mesajı.
  final String title;

  /// Açıklama (bodyMedium, onSurfaceVariant). Kısa, jargonsuz.
  final String? description;

  /// Kaydırılabilir gövde içeriği (form alanları, grid vb.).
  final List<Widget> body;

  /// Gövdenin altına sabitlenen aksiyon(lar) — birincil CTA + ikincil link.
  /// `Column` içine konur; en fazla bir birincil CTA (Design.md §4).
  final List<Widget> actions;

  const AuthScaffold({
    super.key,
    this.appBarTitle,
    this.leading,
    this.icon,
    this.iconColor,
    required this.title,
    this.description,
    this.body = const [],
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: appBarTitle == null
          ? null
          : AppBar(title: Text(appBarTitle!), leading: leading),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 48, color: iconColor ?? scheme.primary),
                      const SizedBox(height: Gap.lg),
                    ],
                    Text(title, style: theme.textTheme.headlineSmall),
                    if (description != null) ...[
                      const SizedBox(height: Gap.sm),
                      Text(
                        description!,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                    const SizedBox(height: Gap.xl),
                    ...body,
                  ],
                ),
              ),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: Gap.md),
                ...actions,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
