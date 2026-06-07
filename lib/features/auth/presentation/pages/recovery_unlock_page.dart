/// Recovery ile açma + YENİ parola (Faz 2 Patch 4).
///
/// 24 kelime VE yeni master parola AYNI formda → tek `recoverWithNewPassword`
/// çağrısı (recoverUnlock + changePassword atomik). "Sadece bu sefer aç" YOK —
/// arada bekleyen masterKey state'i oluşmaz. Tasarım: `AuthScaffold` +
/// `AppTextField` (Design.md §3/§4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/crypto/bip39.dart';
import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/app_text_field.dart';
import '../../../../core/ui/widgets/auth_bits.dart';
import '../../../../core/ui/widgets/auth_scaffold.dart';
import '../../domain/key_manager.dart';
import '../bloc/vault_lock_cubit.dart';
import '../bloc/vault_lock_state.dart';

class RecoveryUnlockPage extends StatefulWidget {
  const RecoveryUnlockPage({super.key});

  @override
  State<RecoveryUnlockPage> createState() => _RecoveryUnlockPageState();
}

class _RecoveryUnlockPageState extends State<RecoveryUnlockPage> {
  final _mnemonicCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _busy = false;

  @override
  void dispose() {
    _mnemonicCtrl
      ..clear()
      ..dispose();
    _passwordCtrl
      ..clear()
      ..dispose();
    super.dispose();
  }

  /// Mnemonic metnini kelime listesine çevirir. Düz boşluklu girişi de,
  /// numaralı yedek formatını da (`1. lizard\n2. goddess ...` — Show ekranının
  /// "Panoya kopyala"sı bunu üretir) kabul eder: her token'ın başındaki sıra
  /// numarasını + noktalamayı ayıkla. Böylece kullanıcı kopyaladığı key'i
  /// doğrudan yapıştırabilir.
  static List<String> _parseWords(String raw) => raw
      .toLowerCase()
      .split(RegExp(r'\s+'))
      // Token başı "12." / "12)" / "12-" gibi numara önekini temizle.
      .map((t) => t.replaceFirst(RegExp(r'^\d+[.)\-]?'), '').trim())
      .where((w) => w.isNotEmpty)
      .toList();

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final words = _parseWords(_mnemonicCtrl.text);
    setState(() => _busy = true);
    try {
      await context
          .read<VaultLockCubit>()
          .recoverWithNewPassword(words, _passwordCtrl.text);
      _mnemonicCtrl.clear();
      _passwordCtrl.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = context.select<VaultLockCubit, VaultLockError?>(
        (c) => c.state.status == VaultLockStatus.locked ? c.state.error : null);

    return Form(
      key: _formKey,
      child: AuthScaffold(
        appBarTitle: 'Recovery key ile aç',
        icon: Icons.key_outlined,
        title: 'Recovery key ile aç',
        description:
            '24 kelimelik recovery key\'ini gir ve yeni bir master parola belirle. '
            'Bundan sonra yeni parolanla açabilirsin.',
        body: [
          AppTextField(
            controller: _mnemonicCtrl,
            label: 'Recovery key (24 kelime)',
            hint: 'kelime1 kelime2 kelime3 ...',
            minLines: 3,
            maxLines: 5,
            autocorrect: false,
            enableSuggestions: false,
            errorText: error == VaultLockError.wrongRecovery
                ? 'Recovery key hatalı'
                : null,
            validator: (v) {
              final n = _parseWords(v ?? '').length;
              return n == Bip39.wordCount
                  ? null
                  : '${Bip39.wordCount} kelime olmalı ($n girildi)';
            },
          ),
          const SizedBox(height: Gap.md),
          AppTextField(
            controller: _passwordCtrl,
            label: 'Yeni master parola',
            obscure: true,
            autocorrect: false,
            enableSuggestions: false,
            helperText: 'En az ${KeyManager.minPasswordLength} karakter',
            errorText: error == VaultLockError.weakPassword
                ? 'Parola çok zayıf'
                : null,
            validator: (v) =>
                (v == null || v.length < KeyManager.minPasswordLength)
                    ? 'En az ${KeyManager.minPasswordLength} karakter'
                    : null,
          ),
        ],
        actions: [
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const BtnSpinner()
                : const Text('Aç ve yeni parolayı kaydet'),
          ),
        ],
      ),
    );
  }
}
