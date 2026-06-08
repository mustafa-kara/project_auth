/// Hesap-vault ilişkilendirme ekranı (Faz 3 Patch 1, reviewer [P2]).
///
/// İlk login'de cihazda uid-siz (Faz 2) vault varsa: kullanıcıya AÇIK seçim sunulur —
/// mevcut vault'u bu hesaba ilişkilendir VEYA yeni boş vault başlat. **Onaysız
/// otomatik migrate YOK** (yanlış hesaba bağlama riski). Her iki seçim de
/// `legacy_link_decided/<uid>` işaretler → `linkRequired` düşer (guard döngüsü yok).
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/di/locator.dart';
import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/auth_bits.dart';
import '../../../../core/ui/widgets/auth_scaffold.dart';
import '../../domain/account_vault_manager.dart';
import '../bloc/session_cubit.dart';

class AccountLinkPage extends StatefulWidget {
  const AccountLinkPage({super.key});

  @override
  State<AccountLinkPage> createState() => _AccountLinkPageState();
}

class _AccountLinkPageState extends State<AccountLinkPage> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function(AccountVaultManager m, String uid) op) async {
    final cubit = context.read<SessionCubit>();
    final uid = cubit.currentUid;
    if (uid == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await op(locator<AccountVaultManager>(), uid);
      // Karar verildi → linkRequired yeniden hesaplanır (false) → guard geçirir.
      await cubit.refreshLinkRequired();
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'İşlem başarısız. Tekrar dene.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = context.select<SessionCubit, String?>((c) => c.state.email);

    return AuthScaffold(
      icon: Icons.devices_other_outlined,
      title: 'Mevcut vault bulundu',
      description: email == null
          ? 'Bu cihazda zaten bir vault var. Bu hesapla ilişkilendirmek ister misin?'
          : 'Bu cihazda zaten bir vault var. $email hesabıyla ilişkilendirmek ister misin?',
      body: [
        Text(
          'İlişkilendirirsen mevcut token\'ların bu hesaba taşınır. '
          'Yeni boş vault başlatırsan mevcut vault korunur (başka bir hesapla açılabilir). '
          'Biyometri her durumda yeniden kurulmalıdır.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        if (_error != null) ...[
          const SizedBox(height: Gap.md),
          AuthErrorText(_error!),
        ],
      ],
      actions: [
        FilledButton(
          onPressed: _busy ? null : () => _run((m, uid) => m.linkLegacyToUser(uid)),
          child: _busy
              ? const BtnSpinner()
              : const Text('Bu hesapla ilişkilendir'),
        ),
        const SizedBox(height: Gap.sm),
        OutlinedButton(
          onPressed: _busy ? null : () => _run((m, uid) => m.startFreshVault(uid)),
          child: const Text('Yeni boş vault başlat'),
        ),
      ],
    );
  }
}
