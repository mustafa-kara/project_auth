/// E-posta onay bekleme ekranı (Faz 3 Patch 1).
///
/// Onay maili gönderildi; kullanıcı linke tıklayınca deep-link → `onAuthStateChange`
/// → `signedIn` → guard otomatik geçer. "Farklı e-posta kullan" pending'i temizler
/// → signedOut → login (guard trap'ini önler, reviewer [P2]).
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/auth_bits.dart';
import '../../../../core/ui/widgets/auth_scaffold.dart';
import '../../domain/auth_exceptions.dart';
import '../bloc/session_cubit.dart';

class EmailConfirmPendingPage extends StatelessWidget {
  const EmailConfirmPendingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<SessionCubit>();
    final email = context.select<SessionCubit, String?>((c) => c.state.email);
    final busy = context.select<SessionCubit, bool>((c) => c.state.busy);
    final error = context.select<SessionCubit, AuthError?>(
      (c) => c.state.error,
    );

    return AuthScaffold(
      icon: Icons.mark_email_unread_outlined,
      title: 'E-postanı onayla',
      description: email == null
          ? 'Sana bir onay maili gönderdik. Linke tıklayınca giriş tamamlanır.'
          : '$email adresine onay maili gönderdik. Linke tıklayınca giriş tamamlanır.',
      body: [if (error != null) AuthErrorText(error.message)],
      actions: [
        FilledButton(
          onPressed: busy ? null : cubit.resend,
          child: busy ? const BtnSpinner() : const Text('Maili tekrar gönder'),
        ),
        const SizedBox(height: Gap.sm),
        TextButton(
          onPressed: busy ? null : cubit.cancelPendingConfirmation,
          child: const Text('Farklı e-posta kullan'),
        ),
      ],
    );
  }
}
