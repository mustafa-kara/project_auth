/// Anahtar metadata okunamadı ekranı (Faz 2 Patch 4).
///
/// `KeyAttributesStore.read()` parse hatası → `keyAttributesCorrupted` → bu ekran.
/// **Recovery vaat etmez:** attrs JSON parse edilemiyorsa `recoveryEncryptedMasterKey`
/// blob'u da okunamaz → recovery mnemonic tek başına masterKey'i AÇAMAZ. Gerçek
/// seçenekler: "Yeniden dene" (geçici okuma hatası) ve son çare "Vault'u sıfırla".
/// Tasarım: `AuthScaffold` (icon=error) (Design.md §3/§4).
///
/// **Yeniden dene geri bildirimi (doğrulama NEW-3):** `retryBootstrap()` başarısız
/// olursa cubit AYNI statüyü tekrar emit eder; ayırt edici tek şey
/// `VaultLockState.attempt` sayacıdır. Bu ekran denemeyi `await` ederken butonu
/// spinner'a çevirir, sonrasında sayaç arttıysa "Hâlâ okunamıyor" snackbar'ı
/// gösterir — aksi halde buton hiçbir şey yapmıyormuş gibi görünüyordu.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/auth_bits.dart';
import '../../../../core/ui/widgets/auth_scaffold.dart';
import '../bloc/vault_lock_cubit.dart';
import '../bloc/vault_lock_state.dart';

class AuthIntegrityPage extends StatefulWidget {
  const AuthIntegrityPage({super.key});

  @override
  State<AuthIntegrityPage> createState() => _AuthIntegrityPageState();
}

class _AuthIntegrityPageState extends State<AuthIntegrityPage> {
  bool _busy = false;

  /// Okuma yeniden denenir; başarısızsa sayaç ilerlediği için bunu görebiliriz.
  Future<void> _retry() async {
    final cubit = context.read<VaultLockCubit>();
    final before = cubit.state.attempt;
    setState(() => _busy = true);
    try {
      await cubit.retryBootstrap();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final after = cubit.state;
    if (after.status == VaultLockStatus.keyAttributesCorrupted &&
        after.attempt > before) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Hâlâ okunamıyor')));
    }
  }

  Future<void> _confirmReset(BuildContext context) async {
    final cubit = context.read<VaultLockCubit>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Vault\'u sıfırla?'),
        content: const Text(
          'Tüm şifreli token\'lar ve anahtar verisi KALICI silinir. '
          'Bu işlem geri alınamaz. Recovery key\'in olsa bile bu cihazdaki '
          'veri gider.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sıfırla'),
          ),
        ],
      ),
    );
    if (confirmed == true) await cubit.resetVault();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AuthScaffold(
      appBarTitle: 'Vault açılamadı',
      icon: Icons.error_outline,
      iconColor: scheme.error,
      title: 'Anahtar verisi okunamadı',
      description:
          'Geçici bir hata olabilir. Yeniden dene; sorun sürerse vault\'u '
          'sıfırlaman gerekebilir.',
      actions: [
        FilledButton(
          onPressed: _busy ? null : _retry,
          child: _busy ? const BtnSpinner() : const Text('Yeniden dene'),
        ),
        const SizedBox(height: Gap.sm),
        OutlinedButton(
          onPressed: _busy ? null : () => _confirmReset(context),
          child: const Text('Vault\'u sıfırla'),
        ),
      ],
    );
  }
}
