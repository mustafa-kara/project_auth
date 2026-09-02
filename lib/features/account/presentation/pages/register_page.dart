/// Kayıt ekranı (Faz 3 Patch 1) — Supabase email/parola.
///
/// Başarı → e-posta onayı bekleniyor (`emailConfirmPending`); guard otomatik
/// `/auth/confirm`'e geçirir. Parola tekrar doğrulaması istemci tarafında.
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

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  String? _localError;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl
      ..clear()
      ..dispose();
    _confirmCtrl
      ..clear()
      ..dispose();
    super.dispose();
  }

  void _register() {
    final email = _emailCtrl.text.trim();
    final pwd = _passwordCtrl.text;
    if (pwd.length < 8) {
      setState(() => _localError = 'Parola en az 8 karakter olmalı.');
      return;
    }
    if (pwd != _confirmCtrl.text) {
      setState(() => _localError = 'Parolalar eşleşmiyor.');
      return;
    }
    setState(() => _localError = null);
    context.read<SessionCubit>().signUp(email: email, password: pwd);
  }

  @override
  Widget build(BuildContext context) {
    final busy = context.select<SessionCubit, bool>((c) => c.state.busy);
    final error = context.select<SessionCubit, AuthError?>(
      (c) => c.state.error,
    );
    final errorMsg = _localError ?? error?.message;

    // Parola alanı içerir → screenshot/recents koruması (SecureScreenScope).
    return SecureScreenScope(
      child: AuthScaffold(
        appBarTitle: 'Kayıt ol',
        leading: const BackButton(),
        title: 'Hesap oluştur',
        description: 'E-posta ile kayıt ol. Onay maili göndereceğiz.',
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
            helperText: 'En az 8 karakter',
          ),
          const SizedBox(height: Gap.md),
          AppTextField(
            controller: _confirmCtrl,
            label: 'Parola (tekrar)',
            obscure: true,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) => busy ? null : _register(),
          ),
          if (errorMsg != null) ...[
            const SizedBox(height: Gap.md),
            AuthErrorText(errorMsg),
          ],
        ],
        actions: [
          FilledButton(
            onPressed: busy ? null : _register,
            child: busy ? const BtnSpinner() : const Text('Kayıt ol'),
          ),
          const SizedBox(height: Gap.sm),
          TextButton(
            onPressed: busy ? null : () => context.goNamed('authLogin'),
            child: const Text('Zaten hesabın var mı? Giriş yap'),
          ),
        ],
      ),
    );
  }
}
