/// Kurulum — recovery key doğrulama (Faz 2 Patch 4).
///
/// Birkaç rastgele konumdaki kelime sorulur; doğruysa `commitSetup()` → **SETUP
/// COMMIT** (bu noktaya kadar diske hiçbir şey yazılmamıştır). Başarısız doğrulama
/// (deneme limiti) veya iptal → `cancelSetup()`. Tasarım: `AuthScaffold` +
/// `AppTextField` (Design.md §3/§4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/platform/secure_screen.dart';
import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/app_text_field.dart';
import '../../../../core/ui/widgets/auth_bits.dart';
import '../../../../core/ui/widgets/auth_scaffold.dart';
import '../bloc/vault_lock_cubit.dart';

class RecoveryVerifyPage extends StatefulWidget {
  const RecoveryVerifyPage({super.key});

  @override
  State<RecoveryVerifyPage> createState() => _RecoveryVerifyPageState();
}

class _RecoveryVerifyPageState extends State<RecoveryVerifyPage> {
  /// Sorulacak kelime konumları (deterministik: 0-tabanlı 2, 9, 17 → testlenebilir).
  static const _positions = [2, 9, 17];

  /// Yanlış deneme limiti (review #4 + kullanıcı kararı: N deneme, sonra iptal).
  /// Eşik aşılınca pending masterKey + mnemonic dispose edilir (cancelSetup) —
  /// böylece key bellekte sınırsız asılı kalmaz, ama tek yazım hatası setup'ı
  /// baştan üretmeye zorlamaz.
  static const _maxAttempts = 3;

  final _controllers = {for (final p in _positions) p: TextEditingController()};
  bool _busy = false;
  String? _error;
  int _attempts = 0;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c
        ..clear()
        ..dispose();
    }
    super.dispose();
  }

  Future<void> _verify() async {
    final cubit = context.read<VaultLockCubit>();
    final mnemonic = cubit.state.mnemonic;
    final ok = _positions.every((p) =>
        _controllers[p]!.text.trim().toLowerCase() == mnemonic[p]);
    if (!ok) {
      _attempts++;
      if (_attempts >= _maxAttempts) {
        // Deneme hakkı bitti → pending masterKey + mnemonic temizlenir (review #4;
        // cubit doc'u ile uyumlu). Kullanıcı setup'a döner, recovery'i baştan üretir.
        cubit.cancelSetup();
        return;
      }
      final remaining = _maxAttempts - _attempts;
      setState(() => _error =
          'Kelimeler eşleşmedi. Tekrar kontrol et ($remaining deneme hakkın kaldı).');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<VaultLockCubit>().commitSetup();
      // Başarılı → guard unlocked'a yönlendirir (router redirect).
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Kurulum tamamlanamadı: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = AuthScaffold(
      appBarTitle: 'Recovery key doğrula',
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Kurulumu iptal et',
        onPressed: () => context.read<VaultLockCubit>().cancelSetup(),
      ),
      title: 'Yedeklediğini doğrula',
      description:
          'Recovery key\'i doğru yazdığından emin olmak için istenen kelimeleri gir.',
      body: [
        for (var i = 0; i < _positions.length; i++) ...[
          AppTextField(
            controller: _controllers[_positions[i]]!,
            label: '${_positions[i] + 1}. kelime',
            autofocus: i == 0,
            autocorrect: false,
            enableSuggestions: false,
          ),
          if (i != _positions.length - 1) const SizedBox(height: Gap.md),
        ],
        if (_error != null) ...[
          const SizedBox(height: Gap.md),
          AuthErrorText(_error!),
        ],
      ],
      actions: [
        FilledButton(
          onPressed: _busy ? null : _verify,
          child: _busy ? const BtnSpinner() : const Text('Kurulumu tamamla'),
        ),
      ],
    );

    // Recovery kelimeleri giriliyor → ekran görüntüsü/recents koruması.
    return SecureScreenScope(child: page);
  }
}
