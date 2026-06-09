/// Bulut restore başarısız ekranı (Faz 3 Patch 2, reviewer [P1] #2).
///
/// Yeni cihazda `key_attributes` sunucudan çekilirken AĞ/RLS hatası olduğunda gösterilir
/// (`VaultLockStatus.restoreFailed`). **`uninitialized`'a DÜŞÜLMEZ** → kullanıcı yanlış
/// bir master parola kurup sunucudaki gerçek vault'u çakıştıramaz.
///
/// **KRİTİK:** bu state'te lokal `key_attributes` YOK → `unlock`/`recover` çağrılırsa
/// `_readAttrsOrThrow()` `StateError` atar. Bu yüzden UnlockPage'e banner EKLENMEZ;
/// ayrı ekran yalnız iki güvenli aksiyon sunar: **Tekrar dene** (`retryRestore`) +
/// **Çıkış / hesap değiştir** (`SessionCubit.signOut`). Parola/biyometri/recovery YOK.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/auth_bits.dart';
import '../../../../core/ui/widgets/auth_scaffold.dart';
import '../../../auth/presentation/bloc/vault_lock_cubit.dart';
import '../bloc/session_cubit.dart';

class RestoreFailedPage extends StatefulWidget {
  const RestoreFailedPage({super.key});

  @override
  State<RestoreFailedPage> createState() => _RestoreFailedPageState();
}

class _RestoreFailedPageState extends State<RestoreFailedPage> {
  bool _busy = false;

  Future<void> _retry() async {
    setState(() => _busy = true);
    try {
      await context.read<VaultLockCubit>().retryRestore();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await context.read<SessionCubit>().signOut();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      icon: Icons.cloud_off_outlined,
      title: 'Buluttan yükleme başarısız',
      description:
          'Hesabının yedeği buluttan alınamadı. İnternet bağlantını kontrol edip '
          'tekrar dene. Bağlantı sorunu sürerse farklı bir hesapla giriş yapabilirsin.',
      body: [
        Text(
          'Güvenlik için bu adım tamamlanmadan yeni bir vault kurulmaz '
          '(mevcut yedeğinin üzerine yazılmasını önler).',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
      actions: [
        FilledButton(
          onPressed: _busy ? null : _retry,
          child: _busy ? const BtnSpinner() : const Text('Tekrar dene'),
        ),
        const SizedBox(height: Gap.sm),
        OutlinedButton(
          onPressed: _busy ? null : _signOut,
          child: const Text('Çıkış yap / hesap değiştir'),
        ),
      ],
    );
  }
}
