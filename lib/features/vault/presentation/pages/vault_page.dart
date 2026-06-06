/// Ana vault ekranı: kayıtlı OTP kodlarının listesi.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/otp/otp_account.dart';
import '../../../../core/otp/otpauth_uri.dart';
import '../bloc/vault_cubit.dart';
import '../widgets/otp_card.dart';

class VaultPage extends StatelessWidget {
  const VaultPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Authenticator')),
      body: BlocBuilder<VaultCubit, VaultState>(
        builder: (context, state) {
          if (state.accounts.isEmpty) {
            return const _EmptyView();
          }
          return ListView.builder(
            itemCount: state.accounts.length,
            itemBuilder: (context, i) {
              final acc = state.accounts[i];
              return OtpCard(
                // Stabil id key: silme/reorder sonrası Flutter, State'i yanlış
                // hesaba reuse edemez (aksi halde TOTP timer'ı durabilir).
                key: ValueKey(acc.id),
                account: acc,
                onIncrement: () =>
                    context.read<VaultCubit>().incrementCounter(acc.id),
                onDelete: () => context.read<VaultCubit>().removeById(acc.id),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddSheet(context),
        icon: const Icon(Icons.add),
        label: const Text('Ekle'),
      ),
    );
  }

  void _showAddSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => _AddSheet(cubit: context.read<VaultCubit>()),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_clock,
              size: 64, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          const Text('Henüz kod yok'),
          const SizedBox(height: 8),
          const Text('Bir otpauth:// bağlantısı ekleyerek başla',
              style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}

/// Manuel `otpauth://` yapıştırma ekleme formu (Faz 1: QR tarama eklenecek).
class _AddSheet extends StatefulWidget {
  final VaultCubit cubit;
  const _AddSheet({required this.cubit});

  @override
  State<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<_AddSheet> {
  final _controller = TextEditingController();
  String? _error;

  void _submit() {
    try {
      final account = OtpAuthUri.parse(_controller.text);
      widget.cubit.add(account);
      Navigator.of(context).pop();
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  void _addDemo() {
    widget.cubit.add(OtpAccount(
      secret: 'JBSWY3DPEHPK3PXP',
      type: OtpType.totp,
      issuer: 'Demo',
      accountName: 'demo@example.com',
    ));
    Navigator.of(context).pop();
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
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Kod ekle', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: 'otpauth:// bağlantısı',
              hintText: 'otpauth://totp/...',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _submit, child: const Text('Ekle')),
          TextButton(onPressed: _addDemo, child: const Text('Demo kodu ekle')),
        ],
      ),
    );
  }
}
