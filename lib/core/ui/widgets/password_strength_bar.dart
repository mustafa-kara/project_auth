/// Parola güç göstergesi (color-not-only: dolu çubuk + metin etiketi + ikon).
///
/// Skor `KeyManager` politikasından türetilir → tek doğruluk noktası. Master
/// parola kurulumu (setup) ve şifreli yedek parolası (export) aynı politikayı
/// kullandığı için bileşen tasarım sistemine taşındı (Faz 5 Patch 1).
library;

import 'package:flutter/material.dart';

import '../../../features/auth/domain/key_manager.dart';
import '../tokens.dart';

class PasswordStrengthBar extends StatelessWidget {
  const PasswordStrengthBar({super.key, required this.password});

  final String password;

  /// 0 = zayıf, 1 = orta, 2 = güçlü. Politika tabanı (min uzunluk + min sınıf)
  /// karşılanmadan "güçlü" verilmez.
  int get _score {
    final len = password.length;
    final classes = KeyManager.passwordClassCount(password);
    if (len < KeyManager.minPasswordLength ||
        classes < KeyManager.minPasswordClasses) {
      return 0;
    }
    if (len >= 16 && classes >= 4) return 2;
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final score = _score;
    // Sabit `Colors.orange`/`Colors.green` yerine şema rolleri: koyu temada ve
    // yüksek kontrast ayarında tema ile birlikte hareket ederler ve `on*`
    // eşleri tanımlı olduğu için kontrast garantisi şemadan gelir.
    final (label, color, icon) = switch (score) {
      0 => ('Zayıf', scheme.error, Icons.warning_amber_rounded),
      1 => ('Orta', scheme.tertiary, Icons.shield_outlined),
      _ => ('Güçlü', scheme.primary, Icons.verified_user_outlined),
    };
    return Semantics(
      label: 'Parola gücü: $label',
      // Çubuk + ikon + metin TEK bir bilgiyi üç kez anlatıyor; alt düğümler
      // dışlanmazsa ekran okuyucu etiketi ("Parola gücü: Orta") hemen ardından
      // aynı metni ("Orta") ve ilerleme çubuğunun yüzdesini tekrar okur.
      excludeSemantics: true,
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.sm),
              child: LinearProgressIndicator(
                value: (score + 1) / 3,
                minHeight: 6,
                backgroundColor: scheme.surfaceContainerHighest,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: Gap.sm),
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
