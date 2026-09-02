/// Manuel `otpauth://` yapıştırma ile kod ekleme sheet'i.
///
/// Phase 5 Patch 3 W0 — moved out of `vault_page.dart` UNCHANGED (behaviour is
/// byte-for-byte the old private `_AddSheet`). W3 grows it with the pasted
/// Google Authenticator migration-link flow (plan §5 D4), which needs its own
/// `MigrationScanController` state and `dispose` — too much to keep inside the
/// page file.
///
/// SECURITY: the pasted text can be a live `otpauth://` URI, i.e. a TOTP seed.
/// The field disables autocorrect/suggestions so the keyboard's learning
/// dictionary never sees it, the controller is cleared on dispose, and nothing
/// here logs or copies the input.
library;

import 'package:flutter/material.dart';

import '../../../../core/otp/otp_account.dart';
import '../../../../core/otp/otpauth_uri.dart';
import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/auth_bits.dart';
import '../../../import_export/data/google_auth_parser.dart';
import '../bloc/vault_cubit.dart';

/// Manuel `otpauth://` yapıştırma ekleme formu.
class AddTokenSheet extends StatefulWidget {
  final VaultCubit cubit;
  const AddTokenSheet({super.key, required this.cubit});

  @override
  State<AddTokenSheet> createState() => _AddTokenSheetState();
}

class _AddTokenSheetState extends State<AddTokenSheet> {
  final _controller = TextEditingController();
  String? _error;

  bool _saving = false;

  Future<void> _submit() async {
    // Google Authenticator aktarım bağlantısı TEK token değil: protobuf'lu bir
    // yığın. `OtpAuthUri.parse` bunu anlamsız bir şema hatasıyla reddederdi →
    // kullanıcıyı doğru girişe yönlendir, `add` ÇAĞIRMA.
    if (GoogleAuthParser.looksLikeMigrationUri(_controller.text)) {
      setState(() => _error = 'Bu bir Google Authenticator aktarım bağlantısı. '
          'Ekle → "QR kod tara" ile okut.');
      return;
    }

    final OtpAccount account;
    try {
      account = OtpAuthUri.parse(_controller.text);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    await _addAndClose(account);
  }

  Future<void> _addDemo() => _addAndClose(OtpAccount(
        secret: 'JBSWY3DPEHPK3PXP',
        type: OtpType.totp,
        issuer: 'Demo',
        accountName: 'demo@example.com',
      ));

  /// Token'ı ekler ve KALICILIĞI bekler; yazma başarılıysa kapatır, hata olursa
  /// formu açık bırakıp hatayı gösterir (kullanıcı "eklendi" sanıp kaybetmesin).
  Future<void> _addAndClose(OtpAccount account) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.cubit.add(account);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = 'Kaydedilemedi: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.sm,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Kod ekle', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _controller,
            // TOTP secret'i otpauth:// içinde gizli sayılır → klavye öğrenme
            // sözlüğüne / öneri çubuğuna sızmasın (parola/recovery alanlarıyla
            // hizalı). visiblePassword: maskelemez ama autocorrect'i kapatır.
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            decoration: InputDecoration(
              labelText: 'otpauth:// bağlantısı',
              hintText: 'otpauth://totp/...',
              errorText: _error,
            ),
            maxLines: 2,
          ),
          const SizedBox(height: Gap.md),
          FilledButton(
            onPressed: _saving ? null : _submit,
            child: _saving ? const BtnSpinner() : const Text('Ekle'),
          ),
          TextButton(
            onPressed: _saving ? null : _addDemo,
            child: const Text('Demo kodu ekle'),
          ),
        ],
      ),
    );
  }
}
