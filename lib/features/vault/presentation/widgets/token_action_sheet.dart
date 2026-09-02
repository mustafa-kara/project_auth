/// Bir kodun üzerine uzun basınca açılan eylem sheet'i.
///
/// Phase 5 Patch 3 (plan §5 D2). BEHAVIOUR CHANGE (risk R10): before this patch
/// a long press on a card deleted the token outright, with no confirmation — a
/// mis-touch while scrolling cost the user access to that account's 2FA. The
/// long press now opens this menu, and the delete entry goes through an
/// explicit confirmation dialog owned by the caller.
///
/// The sheet only ever shows [OtpAccount.label] (issuer + account name); the
/// secret is never read here.
library;

import 'package:flutter/material.dart';

import '../../../../core/otp/otp_account.dart';
import '../../../../core/ui/tokens.dart';

/// What the user picked in [TokenActionSheet]. `null` (a dismissed sheet) means
/// "do nothing" and must leave the token untouched.
enum TokenAction {
  /// Edit issuer / account name (and tags).
  edit,

  /// Jump straight to the tag editor for this token.
  tags,

  /// Delete — the CALLER still has to confirm.
  delete,
}

class TokenActionSheet extends StatelessWidget {
  final OtpAccount account;

  const TokenActionSheet({super.key, required this.account});

  /// Opens the sheet and resolves with the chosen action (null if dismissed).
  static Future<TokenAction?> show(
    BuildContext context, {
    required OtpAccount account,
  }) => showModalBottomSheet<TokenAction>(
    context: context,
    builder: (_) => TokenActionSheet(account: account),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
            child: Text(
              account.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Kodu düzenle'),
            onTap: () => Navigator.of(context).pop(TokenAction.edit),
          ),
          ListTile(
            leading: const Icon(Icons.sell_outlined),
            title: const Text('Etiketleri düzenle'),
            onTap: () => Navigator.of(context).pop(TokenAction.tags),
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: theme.colorScheme.error),
            title: Text(
              'Sil',
              style: TextStyle(color: theme.colorScheme.error),
            ),
            onTap: () => Navigator.of(context).pop(TokenAction.delete),
          ),
          const SizedBox(height: Gap.sm),
        ],
      ),
    );
  }
}
