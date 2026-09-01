/// Şifreli yedek alma ekranı (Faz 5 Patch 1, plan §5.4).
///
/// Vault'un tamamı, KULLANICININ BURADA belirlediği ayrı bir parolayla şifrelenip
/// tek bir JSON dosyasına yazılır (`BackupService.export` → Argon2id + XChaCha20;
/// yeni kripto primitifi yok). Master parola ya da kurtarma anahtarı bu dosyayı
/// AÇMAZ — bu yüzden başarı diyaloğu kaybı açıkça anlatır.
///
/// SECURITY (plan §4.6):
/// - Sayfa [SecureScreenScope] ile sarılıdır (yedek parolası klavyeden giriliyor).
/// - Parola alanları obscure + autocorrect/suggestions kapalı; `dispose`'ta ve
///   başarılı export sonrası temizlenir.
/// - Panoya HİÇBİR ŞEY yazılmaz; şifreli metin ekranda gösterilmez.
/// - Parola politikası `KeyManager.meetsPolicy` (master parola ile AYNI taban) —
///   zayıf parola Argon2id'i işe yaramaz hale getirirdi.
/// - Kaydetme diyaloğu app'i arka plana attığı için
///   `VaultLockCubit.beginSystemFileFlow()` / `finally endSystemFileFlow()`
///   (plan §3.2 — bilinçli, bütçeli kilit muafiyeti).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/crypto/crypto_exceptions.dart';
import '../../../../core/di/locator.dart';
import '../../../../core/platform/secure_screen.dart';
import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/app_text_field.dart';
import '../../../../core/ui/widgets/auth_bits.dart';
import '../../../../core/ui/widgets/auth_scaffold.dart';
import '../../../../core/ui/widgets/empty_state.dart';
import '../../../../core/ui/widgets/password_strength_bar.dart';
import '../../../auth/domain/key_manager.dart';
import '../../../auth/presentation/bloc/vault_lock_cubit.dart';
import '../../../vault/presentation/bloc/vault_cubit.dart';
import '../../domain/backup_service.dart';
import '../../domain/file_port.dart';

/// Yedek dosyasının adı: `projectauth-backup-YYYYMMDD.json`.
String backupFileName(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'projectauth-backup-'
      '${now.year}${two(now.month)}${two(now.day)}.json';
}

class ExportPage extends StatefulWidget {
  /// Servisler testte sahtelenebilsin diye opsiyonel; prod'da DI'dan çözülür.
  const ExportPage({super.key, this.backup, this.documents});

  final BackupService? backup;
  final DocumentPort? documents;

  @override
  State<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends State<ExportPage> {
  late final BackupService _backup = widget.backup ?? locator<BackupService>();
  late final DocumentPort _documents =
      widget.documents ?? locator<DocumentPort>();

  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _passwordCtrl.addListener(_onPasswordChanged);
  }

  void _onPasswordChanged() => setState(() {});

  @override
  void dispose() {
    _passwordCtrl.removeListener(_onPasswordChanged);
    _passwordCtrl
      ..clear()
      ..dispose();
    _confirmCtrl
      ..clear()
      ..dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _passwordCtrl.text;
    if (!KeyManager.meetsPolicy(password)) {
      setState(() => _error =
          'Parola en az ${KeyManager.minPasswordLength} karakter ve '
          '${KeyManager.minPasswordClasses} farklı tür (büyük/küçük harf, '
          'rakam, sembol) içermeli.');
      return;
    }
    if (_confirmCtrl.text != password) {
      setState(() => _error = 'Parolalar eşleşmiyor');
      return;
    }

    final accounts = context.read<VaultCubit>().state.accounts;
    final lock = context.read<VaultLockCubit>();
    setState(() {
      _busy = true;
      _error = null;
    });
    var saved = false;
    try {
      final json = await _backup.export(accounts: accounts, password: password);
      final bytes = Uint8List.fromList(utf8.encode(json));

      // Kaydetme diyaloğu da app'i arka plana atar → aynı bütçeli muafiyet.
      lock.beginSystemFileFlow();
      try {
        saved = await _documents.saveJson(
          fileName: backupFileName(DateTime.now()),
          bytes: bytes,
        );
      } finally {
        lock.endSystemFileFlow();
      }
      if (saved) {
        _passwordCtrl.clear();
        _confirmCtrl.clear();
      }
    } on WeakPasswordException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Yedek oluşturulamadı — tekrar dene.');
      }
    } finally {
      // Uyarı diyaloğu BUSY DIŞINDA açılır: aksi halde CTA spinner'ı diyalog
      // kapanana kadar dönmeye devam ederdi.
      if (mounted) setState(() => _busy = false);
    }
    if (saved && mounted) await _showSuccessDialog();
  }

  /// Kaybın geri dönüşsüz olduğunu AÇIKÇA söyleyen onay diyaloğu (plan §4.6).
  Future<void> _showSuccessDialog() => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.verified_user_outlined),
          title: const Text('Yedek oluşturuldu'),
          content: const Text(
            'Bu yedeği yalnız bu parola açar. Parolanı kaybedersen yedek geri '
            'dönüşsüz kaybolur — master parolan ya da kurtarma anahtarın bu '
            'dosyayı açmaz.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Anladım'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final accounts =
        context.select<VaultCubit, int>((c) => c.state.accounts.length);
    final page = accounts == 0 ? _buildEmpty() : _buildForm(context);

    // Yedek parolası klavyeden giriliyor → hassas ekran (plan §4.6 / D6).
    return SecureScreenScope(child: page);
  }

  Widget _buildEmpty() => Scaffold(
        appBar: AppBar(title: const Text('Şifreli yedek')),
        body: const SafeArea(
          child: EmptyState(
            icon: Icons.inventory_2_outlined,
            title: 'Yedeklenecek token yok',
            description:
                'Vault\'un boş. Önce bir token ekle, sonra buradan şifreli '
                'yedeğini alabilirsin.',
          ),
        ),
      );

  Widget _buildForm(BuildContext context) => AuthScaffold(
        appBarTitle: 'Şifreli yedek',
        icon: Icons.shield_outlined,
        title: 'Şifreli yedek al',
        description:
            'Tüm tokenların burada belirleyeceğin AYRI bir parolayla '
            'şifrelenip tek bir dosyaya yazılır. Dosya cihazından çıkmaz; '
            'nereye kaydedeceğine sen karar verirsin.',
        body: [
          AppTextField(
            controller: _passwordCtrl,
            label: 'Yedek parolası',
            obscure: true,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            helperText: 'En az ${KeyManager.minPasswordLength} karakter, '
                'en az ${KeyManager.minPasswordClasses} farklı tür '
                '(büyük/küçük harf, rakam, sembol)',
          ),
          if (_passwordCtrl.text.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            PasswordStrengthBar(password: _passwordCtrl.text),
          ],
          const SizedBox(height: Gap.md),
          AppTextField(
            controller: _confirmCtrl,
            label: 'Parola (tekrar)',
            obscure: true,
            autocorrect: false,
            enableSuggestions: false,
          ),
          const SizedBox(height: Gap.md),
          Text(
            'Bu parolayı master parolandan farklı seçebilirsin — ama '
            'kaybedersen yedek geri dönüşsüz kaybolur.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          if (_error != null) ...[
            const SizedBox(height: Gap.md),
            AuthErrorText(_error!),
          ],
        ],
        actions: [
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy ? const BtnSpinner() : const Text('Yedek oluştur'),
          ),
        ],
      );
}
