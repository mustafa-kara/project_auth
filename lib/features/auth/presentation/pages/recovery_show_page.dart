/// Kurulum — recovery key (24 kelime) gösterimi (Faz 2 Patch 4).
///
/// Mnemonic `VaultLockCubit` setupPending state'inden okunur (bellekte, henüz
/// persist edilmedi). 24 kelime **2×12 numaralı grid**'te (MnemonicGrid) tek
/// ekranda görünür → kullanıcı hepsini görmeden ilerleyemez. "Yazdım" onayı
/// işaretlenmeden "Devam" pasif. Kopyala butonu (kullanıcı parola yöneticisine
/// alabilsin) + güvenlik uyarısı.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/auth_scaffold.dart';
import '../../../../core/ui/widgets/mnemonic_grid.dart';
import '../bloc/vault_lock_cubit.dart';

class RecoveryShowPage extends StatefulWidget {
  const RecoveryShowPage({super.key});

  @override
  State<RecoveryShowPage> createState() => _RecoveryShowPageState();
}

class _RecoveryShowPageState extends State<RecoveryShowPage> {
  bool _acknowledged = false;

  Future<void> _copy(List<String> words) async {
    // Numaralı kopyala: "1. lizard\n2. goddess\n..." → yapıştırınca sıra korunur
    // (kullanıcı hangi kelime kaçıncı görür; düz "kelime kelime" sırayı gizler).
    final numbered = [
      for (var i = 0; i < words.length; i++) '${i + 1}. ${words[i]}',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: numbered));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
          const SnackBar(content: Text('Recovery key panoya kopyalandı')));
  }

  @override
  Widget build(BuildContext context) {
    final mnemonic =
        context.select<VaultLockCubit, List<String>>((c) => c.state.mnemonic);
    final scheme = Theme.of(context).colorScheme;

    return AuthScaffold(
      appBarTitle: 'Recovery key',
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Kurulumu iptal et',
        onPressed: () => context.read<VaultLockCubit>().cancelSetup(),
      ),
      title: 'Recovery key\'ini yedekle',
      description:
          'Bu 24 kelime parolanı unutursan vault\'u açmanın TEK yolu. Güvenli '
          'bir yere yaz (kâğıt veya parola yöneticisi). Kimseyle paylaşma, '
          'ekran görüntüsü alma.',
      body: [
        MnemonicGrid(words: mnemonic),
        const SizedBox(height: Gap.md),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _copy(mnemonic),
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Panoya kopyala'),
          ),
        ),
        const SizedBox(height: Gap.sm),
        // Açık onay: kullanıcı 24 kelimeyi gördü + yedekledi diye işaretler.
        // Grid tek ekranda göründüğü için "görmeden onayladı" durumu kalkar.
        Card(
          color: scheme.surfaceContainerHigh,
          child: CheckboxListTile(
            value: _acknowledged,
            onChanged: (v) => setState(() => _acknowledged = v ?? false),
            title: const Text('24 kelimeyi güvenli biçimde yedekledim'),
            controlAffinity: ListTileControlAffinity.leading,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
          ),
        ),
      ],
      actions: [
        FilledButton(
          onPressed:
              _acknowledged ? () => context.goNamed('recoveryVerify') : null,
          child: const Text('Devam'),
        ),
      ],
    );
  }
}
