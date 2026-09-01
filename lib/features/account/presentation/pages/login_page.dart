/// Giriş ekranı (Faz 3 Patch 1) — Supabase email/parola.
///
/// Login parolası ≠ master parola (ayrı kapı). Başarılı giriş → `signedIn` →
/// guard vault akışına geçirir. Onaysız e-posta → inline hata + onay ekranı.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/platform/secure_screen.dart';
import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/app_text_field.dart';
import '../../../../core/ui/widgets/auth_bits.dart';
import '../../../../core/ui/widgets/auth_scaffold.dart';
import '../../domain/auth_exceptions.dart';
import '../bloc/session_cubit.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl
      ..clear()
      ..dispose();
    super.dispose();
  }

  void _signIn() {
    context.read<SessionCubit>().signIn(
          email: _emailCtrl.text.trim(),
          password: _passwordCtrl.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final busy =
        context.select<SessionCubit, bool>((c) => c.state.busy);
    final error =
        context.select<SessionCubit, AuthError?>((c) => c.state.error);
    final notConfirmed = error is AuthEmailNotConfirmed;

    // Parola alanı içerir → screenshot/recents koruması (SecureScreenScope).
    return SecureScreenScope(
      child: AuthScaffold(
        icon: Icons.login,
        title: 'Giriş yap',
        description: 'Hesabına giriş yap. Bu parola, vault master parolandan ayrıdır.',
        body: [
          AppTextField(
            controller: _emailCtrl,
            label: 'E-posta',
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            enableSuggestions: false,
            autofocus: true,
          ),
          const SizedBox(height: Gap.md),
          AppTextField(
            controller: _passwordCtrl,
            label: 'Parola',
            obscure: true,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) => busy ? null : _signIn(),
          ),
          if (error != null) ...[
            const SizedBox(height: Gap.md),
            AuthErrorText(error.message),
          ],
          if (notConfirmed) ...[
            const SizedBox(height: Gap.sm),
            TextButton(
              onPressed: busy ? null : () => context.goNamed('authConfirm'),
              child: const Text('E-postanı onayla'),
            ),
          ],
        ],
        actions: [
          FilledButton(
            onPressed: busy ? null : _signIn,
            child: busy ? const BtnSpinner() : const Text('Giriş yap'),
          ),
          const SizedBox(height: Gap.sm),
          TextButton(
            onPressed: busy ? null : () => context.goNamed('authRegister'),
            child: const Text('Hesabın yok mu? Kayıt ol'),
          ),
        ],
      ),
    );
  }
}
