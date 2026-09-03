/// Kurulum — recovery key (24 kelime) gösterimi (Faz 2 Patch 4).
///
/// Mnemonic `VaultLockCubit` setupPending state'inden okunur (bellekte, henüz
/// persist edilmedi). 24 kelime **2×12 numaralı grid**'te (MnemonicGrid) tek
/// ekranda görünür → kullanıcı hepsini görmeden ilerleyemez. "Yazdım" onayı
/// işaretlenmeden "Devam" pasif. Kopyala butonu (kullanıcı parola yöneticisine
/// alabilsin) + güvenlik uyarısı.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/platform/secure_screen.dart';
import '../../../../core/platform/sensitive_clipboard.dart';
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

  /// Recovery key master-key recovery sağladığı için panoda kalıcı bırakılmaz:
  /// kopyalamadan ~[_clearAfter] sonra koşullu temizlenir. Pano hâlâ bizim
  /// yazdığımız değeri tutuyorsa silinir; kullanıcı arada başka bir şey
  /// kopyaladıysa DOKUNULMAZ (onun verisini ezmeyiz).
  static const Duration _clearAfter = Duration(seconds: 60);
  Timer? _clearTimer;
  String? _copiedValue;

  @override
  void dispose() {
    // NOTE: _clearTimer is intentionally NOT cancelled — if the user taps
    // "Devam" (or otherwise leaves) before the 60s window elapses, the recovery
    // key must STILL be wiped from the clipboard. The recovery key is the most
    // sensitive value in the app (permanent master-key recovery), so leaving it
    // in the clipboard indefinitely is worse than for an OTP. The callback is
    // disposed-safe (touches only instance fields + Clipboard, no context).
    super.dispose();
  }

  Future<void> _copy(List<String> words) async {
    // Numaralı kopyala: "1. lizard\n2. goddess\n..." → yapıştırınca sıra korunur
    // (kullanıcı hangi kelime kaçıncı görür; düz "kelime kelime" sırayı gizler).
    final numbered = [
      for (var i = 0; i < words.length; i++) '${i + 1}. ${words[i]}',
    ].join('\n');
    // Düz `Clipboard.setData` DEĞİL: recovery key master-key eşdeğeri olduğu
    // için pano yazımı cihaz-yerel (iOS Universal Clipboard KAPALI) ve OS
    // düzeyinde süreli olmalı — süreç öldürülürse alttaki Dart timer'ı hiç
    // çalışmaz, `expiresIn` ise yine de geçerlidir (review [P2-4]).
    await SensitiveClipboard.setText(numbered, expiresIn: _clearAfter);
    _copiedValue = numbered;
    _clearTimer?.cancel();
    _clearTimer = Timer(_clearAfter, _clearClipboardIfUnchanged);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text(
            'Recovery key panoya kopyalandı — yalnız bu cihazda kalır '
            '(diğer cihazlarına geçmez) ve 60 sn sonra silinir',
          ),
        ),
      );
  }

  /// Pano hâlâ bizim kopyaladığımız değeri tutuyorsa temizle.
  Future<void> _clearClipboardIfUnchanged() async {
    final copied = _copiedValue;
    if (copied == null) return;
    final current = await Clipboard.getData(Clipboard.kTextPlain);
    if (current?.text == copied) {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
    _copiedValue = null;
  }

  @override
  Widget build(BuildContext context) {
    final mnemonic = context.select<VaultLockCubit, List<String>>(
      (c) => c.state.mnemonic,
    );
    final scheme = Theme.of(context).colorScheme;

    final page = AuthScaffold(
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
          onPressed: _acknowledged
              ? () => context.goNamed('recoveryVerify')
              : null,
          child: const Text('Devam'),
        ),
      ],
    );

    // 24 kelime ekranda → ekran görüntüsü/recents koruması (hassas ekran).
    return SecureScreenScope(child: page);
  }
}
