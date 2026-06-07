/// Kurulum — master parola oluşturma (Faz 2 Patch 4).
///
/// Parola + tekrar girilir; `VaultLockCubit.beginSetup` çağrılır (DİSKE YAZMAZ) →
/// recovery göster ekranına geçilir. Tasarım dili: `AuthScaffold` + `AppTextField`
/// (Design.md §3/§4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/crypto/crypto_exceptions.dart';
import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/app_text_field.dart';
import '../../../../core/ui/widgets/auth_bits.dart';
import '../../../../core/ui/widgets/auth_scaffold.dart';
import '../../domain/key_manager.dart';
import '../bloc/vault_lock_cubit.dart';

class SetupPasswordPage extends StatefulWidget {
  const SetupPasswordPage({super.key});

  @override
  State<SetupPasswordPage> createState() => _SetupPasswordPageState();
}

class _SetupPasswordPageState extends State<SetupPasswordPage> {
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _passwordCtrl
      ..clear()
      ..dispose();
    _confirmCtrl
      ..clear()
      ..dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<VaultLockCubit>().beginSetup(_passwordCtrl.text);
      _passwordCtrl.clear();
      _confirmCtrl.clear();
      if (mounted) context.goNamed('recoveryShow');
    } on WeakPasswordException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Kurulum başarısız: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: AuthScaffold(
        icon: Icons.lock_outline,
        title: 'Vault\'unu koru',
        description:
            'Tokenlarını şifrelemek için bir master parola belirle. Bu parolayı '
            'unutursan vault\'u yalnız recovery key ile açabilirsin.',
        body: [
          AppTextField(
            controller: _passwordCtrl,
            label: 'Master parola',
            obscure: true,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            helperText: 'En az ${KeyManager.minPasswordLength} karakter',
            validator: (v) =>
                (v == null || v.length < KeyManager.minPasswordLength)
                    ? 'En az ${KeyManager.minPasswordLength} karakter'
                    : null,
          ),
          const SizedBox(height: Gap.md),
          AppTextField(
            controller: _confirmCtrl,
            label: 'Parola (tekrar)',
            obscure: true,
            autocorrect: false,
            enableSuggestions: false,
            validator: (v) =>
                v != _passwordCtrl.text ? 'Parolalar eşleşmiyor' : null,
          ),
          if (_error != null) ...[
            const SizedBox(height: Gap.md),
            AuthErrorText(_error!),
          ],
        ],
        actions: [
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy ? const BtnSpinner() : const Text('Devam'),
          ),
        ],
      ),
    );
  }
}
