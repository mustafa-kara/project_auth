/// Kilit açma — master parola (Faz 2 Patch 4).
///
/// Doğru parola → vault (guard yönlendirir). Yanlış parola → inline hata, kilitli
/// kalır. "Parolamı unuttum → recovery key" linki recovery ekranına götürür.
/// Tasarım: `AuthScaffold` + `AppTextField` (Design.md §3/§4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/platform/secure_screen.dart';
import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/app_text_field.dart';
import '../../../../core/ui/widgets/auth_bits.dart';
import '../../../../core/ui/widgets/auth_scaffold.dart';
import '../bloc/vault_lock_cubit.dart';
import '../bloc/vault_lock_state.dart';

class UnlockPage extends StatefulWidget {
  const UnlockPage({super.key});

  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  final _passwordCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _passwordCtrl
      ..clear()
      ..dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    setState(() => _busy = true);
    try {
      await context.read<VaultLockCubit>().unlock(_passwordCtrl.text);
      _passwordCtrl.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _biometricUnlock() async {
    setState(() => _busy = true);
    try {
      await context.read<VaultLockCubit>().biometricUnlock();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _errorText(VaultLockError? error) {
    switch (error) {
      case VaultLockError.wrongPassword:
        return 'Parola hatalı';
      case VaultLockError.biometricLockout:
        return 'Biyometri kilitlendi — parola ile aç';
      case VaultLockError.biometricFailed:
        return 'Biyometrik doğrulama başarısız — parola ile dene';
      case VaultLockError.wrongRecovery:
      case VaultLockError.weakPassword:
      case null:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = context.select<VaultLockCubit, VaultLockError?>(
        (c) => c.state.status == VaultLockStatus.locked ? c.state.error : null);
    // Biyometri butonu: yalnız enrolled + cihaz uygun (türetilmiş kesişim).
    final biometricAvailable = context.select<VaultLockCubit, bool>(
        (c) => c.state.biometricUnlockAvailable);
    // Parola alanı hatası yalnız parola/biyometri hata sebepleri için.
    final pwdError = _errorText(error);

    final page = AuthScaffold(
      icon: Icons.lock_outline,
      title: 'Vault kilitli',
      description: 'Devam etmek için master parolanı gir.',
      body: [
        AppTextField(
          controller: _passwordCtrl,
          label: 'Master parola',
          obscure: true,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          errorText: pwdError,
          onSubmitted: (_) => _busy ? null : _unlock(),
        ),
      ],
      actions: [
        FilledButton(
          onPressed: _busy ? null : _unlock,
          child: _busy ? const BtnSpinner() : const Text('Aç'),
        ),
        if (biometricAvailable) ...[
          const SizedBox(height: Gap.sm),
          OutlinedButton.icon(
            onPressed: _busy ? null : _biometricUnlock,
            icon: const Icon(Icons.fingerprint),
            label: const Text('Biyometri ile aç'),
          ),
        ],
        const SizedBox(height: Gap.sm),
        TextButton(
          onPressed: () => context.goNamed('recovery'),
          child: const Text('Parolamı unuttum → recovery key'),
        ),
      ],
    );

    // Master parola klavyeden giriliyor → ekran görüntüsü / ekran kaydı /
    // recents önizleme koruması (hassas ekran).
    return SecureScreenScope(child: page);
  }
}
