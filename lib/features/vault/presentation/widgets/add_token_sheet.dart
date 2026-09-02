/// Manuel `otpauth://` yapıştırma ile kod ekleme sheet'i — ve Faz 5 Patch 3'ten
/// beri Google Authenticator AKTARIM bağlantılarının yapıştırıldığı yer.
///
/// İki yol, tek alan:
/// - **Tek token:** `otpauth://…` → `OtpAuthUri.parse` → `VaultCubit.add`.
///   Davranış Patch 2'dekiyle birebir aynı.
/// - **Aktarım bağlantısı (Patch 3, plan §5 D4):** `otpauth-migration://…`
///   yapıştırılırsa metin [MigrationScanController]'a verilir. Çok parçalı bir
///   dışa aktarma birden çok bağlantı üretir; eksikken [MigrationProgressBand]
///   ilerlemeyi gösterir, tamamlanınca ortak [ImportPreviewView] onaya sunulur.
///   QR'ı taratamayan (tek cihazlı, kamerasız, kırık kameralı) kullanıcının
///   TEK yolu budur — Patch 2'de burası kullanıcıyı kameraya yönlendiriyordu.
///
/// SECURITY:
/// - Yapıştırılan metin CANLI secret'tır (tek token'da `?secret=`, aktarımda
///   protobuf yığını). Alan autocorrect/öneri kapalı açılır (klavye öğrenme
///   sözlüğü görmesin), aktarım yolunda her gönderimden sonra ve `dispose`'ta
///   temizlenir, hiçbir yolda loglanmaz/kopyalanmaz.
/// - Pano PROGRAMATİK OKUNMAZ: yapıştırmayı kullanıcı yapar (plan §5 R8).
/// - Hiçbir hata metni ham girdiyi taşımaz; aktarım hatalarında neden bile
///   açıklanmaz (secret'tan türer — bkz. [MigrationScanController.handleRaw]).
/// - Toplanan hesaplar yalnız controller'ın içinde yaşar; `dispose`'ta reset.
library;

import 'package:flutter/material.dart';

import '../../../../core/di/locator.dart';
import '../../../../core/otp/otp_account.dart';
import '../../../../core/otp/otpauth_uri.dart';
import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/auth_bits.dart';
import '../../../import_export/data/google_auth_parser.dart';
import '../../../import_export/domain/import_exceptions.dart';
import '../../../import_export/domain/import_service.dart';
import '../../../import_export/presentation/widgets/import_preview_view.dart';
import '../../../import_export/presentation/widgets/migration_progress_band.dart';
import '../../../scan/presentation/migration_scan_controller.dart';
import '../bloc/vault_cubit.dart';

/// Manuel `otpauth://` / `otpauth-migration://` yapıştırma formu.
class AddTokenSheet extends StatefulWidget {
  const AddTokenSheet({super.key, required this.cubit, this.debugMigration});

  final VaultCubit cubit;

  /// Test tohumu: migration beynini enjekte eder. Prod'da `null` → DI'daki
  /// [ImportService] ile TEMBEL kurulur, böylece tek-token yapıştırması
  /// locator'a HİÇ dokunmaz (locator'sız widget testleri bozulmasın).
  @visibleForTesting
  final MigrationScanController? debugMigration;

  @override
  State<AddTokenSheet> createState() => _AddTokenSheetState();
}

class _AddTokenSheetState extends State<AddTokenSheet> {
  final _controller = TextEditingController();
  String? _error;

  bool _saving = false;

  /// Migration beyni — bkz. [AddTokenSheet.debugMigration].
  MigrationScanController? _migration;
  MigrationScanController get _migrationController =>
      _migration ??= MigrationScanController(locator<ImportService>());

  /// Aktarım sayaçları. [_total] > 0 ise sheet aktarım modundadır.
  int _scanned = 0;
  int _total = 0;

  /// Onaya sunulan önizleme; doluysa form yerine önizleme render edilir.
  ImportPreview? _preview;
  String? _importError;

  /// Aynı anda iki "baştan başla" diyaloğu açılmasın.
  bool _dialogOpen = false;

  bool get _isComplete => _total > 0 && _scanned >= _total;

  @override
  void initState() {
    super.initState();
    _migration = widget.debugMigration;
  }

  @override
  void dispose() {
    // Toplanan hesaplar canlı secret taşır → sheet kapanırken düşür.
    _migration?.reset();
    _controller
      ..clear()
      ..dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final raw = _controller.text;

    // Google Authenticator aktarım bağlantısı TEK token değil: protobuf'lu bir
    // yığın. `OtpAuthUri.parse` bunu anlamsız bir şema hatasıyla reddederdi →
    // ayrı yola sok.
    if (GoogleAuthParser.looksLikeMigrationUri(raw)) {
      await _handleMigrationLink(raw);
      return;
    }

    final OtpAccount account;
    try {
      account = OtpAuthUri.parse(raw);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    await _addAndClose(account);
  }

  /// Aktarım bağlantısı → controller olayı → UI. Ham metin burada tüketilir ve
  /// hiçbir alana yazılmaz.
  Future<void> _handleMigrationLink(String raw) async {
    final MigrationScanEvent event;
    try {
      event = _migrationController.handleRaw(raw);
    } finally {
      // Bağlantı canlı secret taşır ve işi bitti: sonuç ne olursa olsun alan
      // temizlenir. Kullanıcı için de doğru davranış — sıradaki bağlantıyı
      // yapıştırmadan önce eskisini silmek zorunda kalmaz.
      _controller.clear();
    }

    switch (event) {
      case MigrationScanComplete(:final scanned, :final total):
        setState(() {
          _scanned = scanned;
          _total = total;
          _error = null;
        });
        await _showPreview();
      case MigrationBatchAdded(:final scanned, :final total):
        setState(() {
          _scanned = scanned;
          _total = total;
          _error = null;
        });
      case MigrationDuplicateScan():
        setState(() => _error = 'Bu bağlantı zaten eklendi');
      case MigrationDifferentBatch():
        await _askRestart();
      case MigrationInvalidBatch() || MigrationMalformedQr():
        // Neden ayrımı KASITLI olarak gösterilmez (secret'tan türer).
        setState(
          () => _error =
              'Bu bağlantı bir Google Authenticator aktarım '
              'bağlantısı değil ya da bozuk.',
        );
      case MigrationScanFull():
        setState(() => _error = 'Bu aktarımda çok fazla hesap var.');
    }
  }

  /// Başka bir dışa aktarmanın bağlantısı yapıştırıldı: birleştirme YAPILMAZ.
  Future<void> _askRestart() async {
    if (_dialogOpen) return;
    _dialogOpen = true;
    final bool? restart;
    try {
      restart = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: const Text(
            'Bu bağlantı farklı bir dışa aktarmaya ait. Baştan başlansın mı?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Vazgeç'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Baştan başla'),
            ),
          ],
        ),
      );
    } finally {
      // `showDialog` atarsa bayrak takılı kalmamalı (bkz. ScanPage._askRestart).
      _dialogOpen = false;
    }
    if (restart == true && mounted) _restart();
  }

  void _restart() {
    _migration?.reset();
    if (!mounted) return;
    setState(() {
      _scanned = 0;
      _total = 0;
      _preview = null;
      _error = null;
      _importError = null;
    });
  }

  /// Toplananları önizlemeye çevirir.
  ///
  /// "Bu kadar yeter" buraya DOĞRUDAN gelir, ScanPage'deki gibi ayrı bir onay
  /// diyaloğundan geçmeden: önizleme adımının kendisi zaten sayıları gösteren
  /// bir onaydır ve sheet'te yanlışlıkla basma riski kamera ekranındaki kadar
  /// yüksek değil (buton kadrajın altında sürekli durmuyor).
  Future<void> _showPreview() async {
    final existing = widget.cubit.state.accounts;
    final ImportPreview preview;
    try {
      preview = _migrationController.preview(existing: existing);
    } on EmptyImportException {
      setState(
        () => _error = 'Bu bağlantılarda içe aktarılacak token bulunamadı.',
      );
      return;
    }
    if (!mounted) return;
    setState(() {
      _preview = preview;
      _importError = null;
    });
  }

  /// Onay: hepsi TEK `addAll` ile eklenir (tek persist + tek push).
  Future<void> _confirmImport() async {
    final preview = _preview;
    if (preview == null || preview.toAdd.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _saving = true;
      _importError = null;
    });
    try {
      await widget.cubit.addAll(preview.toAdd);
      _migration?.reset(); // secret'lar artık vault'ta → bellekte tutma
      messenger.showSnackBar(
        SnackBar(content: Text('${preview.addCount} token eklendi')),
      );
      if (mounted) navigator.pop();
    } catch (_) {
      // Kaydedilemedi → sheet KAPANMAZ, kullanıcı tekrar deneyebilir.
      if (mounted) {
        setState(() => _importError = 'Tokenlar kaydedilemedi — tekrar dene.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addDemo() => _addAndClose(
    OtpAccount(
      secret: 'JBSWY3DPEHPK3PXP',
      type: OtpType.totp,
      issuer: 'Demo',
      accountName: 'demo@example.com',
    ),
  );

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
  Widget build(BuildContext context) {
    final preview = _preview;
    if (preview != null) return _buildPreview(context, preview);
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
          if (_total == 0)
            TextButton(
              onPressed: _saving ? null : _addDemo,
              child: const Text('Demo kodu ekle'),
            ),
          if (_total > 0) ...[
            const SizedBox(height: Gap.md),
            MigrationProgressBand(
              scanned: _scanned,
              total: _total,
              complete: _isComplete,
              progressLabel: 'bağlantı eklendi',
              remainingHint: 'Kalan bağlantıları da yapıştır',
              onContinue: _showPreview,
              onStopEarly: _showPreview,
              onRestart: _restart,
            ),
          ],
        ],
      ),
    );
  }

  /// Önizleme sheet'in İÇİNDE gösterilir: yeni bir rota açmak, toplanan
  /// hesapları taşıyan state'i sheet'ten koparırdı.
  ///
  /// [ImportPreviewView] `Expanded` kullanır → sınırlı yükseklik şart. Ekranın
  /// %85'i: liste için bol yer bırakır, altındaki sayfanın görünen şeridi de
  /// kullanıcıya hâlâ bir sheet'te olduğunu söyler.
  Widget _buildPreview(BuildContext context, ImportPreview preview) => SizedBox(
    height: MediaQuery.sizeOf(context).height * 0.85,
    child: ImportPreviewView(
      preview: preview,
      headerLabel: 'Google Authenticator',
      headerDetail: '$_scanned/$_total bağlantı',
      error: _importError,
      busy: _saving,
      onConfirm: _confirmImport,
    ),
  );
}
