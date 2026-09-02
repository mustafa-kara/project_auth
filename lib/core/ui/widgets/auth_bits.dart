/// Auth ekranlarında tekrar eden küçük parçalar — inline hata + CTA spinner.
/// Tutarlı görünüm (Design.md §4: hata error renginde + ikon; CTA içi spinner).
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

/// Inline hata metni (ikon + error renk). Form/submit hatalarında kullanılır.
class AuthErrorText extends StatelessWidget {
  final String message;
  const AuthErrorText(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, size: 18, color: scheme.error),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(
            message,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ),
      ],
    );
  }
}

/// CTA butonu içi yükleniyor göstergesi (FilledButton child'ı olarak).
class BtnSpinner extends StatelessWidget {
  const BtnSpinner({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 20,
    width: 20,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}
