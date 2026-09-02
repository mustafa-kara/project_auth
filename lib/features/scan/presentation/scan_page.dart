/// QR tarama ekranı — `mobile_scanner` ile kamera taraması, iki mod:
///
/// - **Tek token:** ilk geçerli `otpauth://` QR'ı yakalandığında token vault'a
///   eklenir ve ekran kapanır.
/// - **Google Authenticator aktarımı (Faz 5 Patch 2):** `otpauth-migration://`
///   şeması görülür görülmez ekran migration moduna geçer; çok parçalı bir
///   dışa aktarmanın QR'ları sırayla toplanır, sonra ortak içe aktarma
///   önizlemesi onaya sunulur. Yeni rota YOK — mod şemadan anlaşılır.
///
/// SECURITY:
/// - Sayfa [SecureScreenScope] ile sarılıdır: kamera önizlemesi QR'ın KENDİSİNİ
///   (yani düz secret'ları) gösterir, önizleme adımı da issuer/hesap listesi.
/// - Ham QR metni parse edildikten sonra TUTULMAZ; panoya hiçbir şey yazılmaz;
///   secret hiçbir mesaja/loga girmez (hata metinleri sabit).
/// - Toplanan hesaplar yalnız controller'ın içinde yaşar; `dispose`'ta reset.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/di/locator.dart';
import '../../../core/otp/otp_account.dart';
import '../../../core/otp/otpauth_uri.dart';
import '../../../core/platform/secure_screen.dart';
import '../../../core/ui/tokens.dart';
import '../../../core/ui/widgets/empty_state.dart';
import '../../import_export/data/google_auth_parser.dart';
import '../../import_export/domain/import_exceptions.dart';
import '../../import_export/domain/import_service.dart';
import '../../import_export/presentation/widgets/import_preview_view.dart';
import '../../vault/presentation/bloc/vault_cubit.dart';
import 'migration_scan_controller.dart';

/// Kamera widget'ının yerine geçen test kurucusu: [onRaw]'ı çağırmak, bir QR
/// karesinin okunmasıyla aynı yola girer.
typedef ScannerBuilder = Widget Function(
    BuildContext context, void Function(String raw) onRaw);

class ScanPage extends StatefulWidget {
  const ScanPage({
    super.key,
    this.debugMigration,
    this.debugScannerBuilder,
    this.debugRestartCamera,
  });

  /// Test tohumu: migration beynini enjekte eder. Prod'da `null` → DI'daki
  /// [ImportService] ile gerçek [MigrationScanController] kurulur.
  @visibleForTesting
  final MigrationScanController? debugMigration;

  /// Test tohumu: [MobileScanner] host VM'de kamera/plugin ister → widget
  /// testinde yerine bu kurucunun döndürdüğü yer tutucu render edilir.
  @visibleForTesting
  final ScannerBuilder? debugScannerBuilder;

  /// Test tohumu: `stop()`+`start()` kamera yeniden başlatmasının yerine geçer
  /// (bkz. [_ScanPageState._restartCamera]).
  @visibleForTesting
  final Future<void> Function()? debugRestartCamera;

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );

  /// Migration beyni. Tembel kurulur: tek-token taraması DI'ya HİÇ dokunmaz
  /// (locator'sız widget testleri bozulmasın).
  MigrationScanController? _migration;
  MigrationScanController get _migrationController =>
      _migration ??= MigrationScanController(locator<ImportService>());

  /// İlk başarılı yakalamadan sonra tekrar işlemeyi (ve çift ekleme/çift pop'u)
  /// engeller. Kamera akışı birden çok kare yollayabilir. Migration modunda
  /// KİLİTLEMEZ — orada birden çok QR okunması işin ta kendisi.
  bool _handled = false;

  /// Migration sayaçları. [_total] > 0 ise ekran migration modundadır.
  int _scanned = 0;
  int _total = 0;

  /// Onaya sunulan önizleme; doluysa kamera yerine önizleme render edilir.
  ImportPreview? _preview;
  bool _busy = false;
  String? _importError;

  /// Aynı QR'ın arka arkaya gelen kareleri diyalogları üst üste yığmasın
  /// (iOS'ta `noDuplicates` payload karşılaştırması YAPMAZ — aşağıdaki nota bak).
  bool _dialogOpen = false;

  bool get _isComplete => _total > 0 && _scanned >= _total;

  @override
  void initState() {
    super.initState();
    _migration = widget.debugMigration;
  }

  @override
  void dispose() {
    // Toplanan hesaplar canlı secret taşır → ekran kapanırken düşür.
    _migration?.reset();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
    if (raw == null) return;
    await _handleRaw(raw);
  }

  /// Tek giriş noktası: hem kameradan hem test tohumundan buraya gelinir.
  Future<void> _handleRaw(String raw) async {
    // Önizleme açıkken kamera zaten durdurulmuştur; gecikmiş bir kare gelirse
    // onay ekranının altını oymasın.
    if (_preview != null) return;

    if (GoogleAuthParser.looksLikeMigrationUri(raw)) {
      _handleMigration(raw);
      return;
    }

    // Migration yarıdayken araya giren tek-token QR'ı sessizce EKLEMEZ: aksi
    // hâlde toplanan parçalar kaybolur ve ekran habersiz kapanırdı.
    if (_total > 0) {
      _showError('Bu QR bir Google Authenticator aktarım kodu değil ya da bozuk.');
      return;
    }

    if (_handled) return;

    final OtpAccount account;
    try {
      account = OtpAuthUri.parse(raw);
    } on FormatException catch (e) {
      // Geçersiz/QR-değil — kullanıcıyı bilgilendir, taramaya devam et.
      _showError('Geçersiz QR: ${e.message}');
      return;
    }

    _handled = true; // yalnızca geçerli QR'da kilitle — geçersizde taramaya devam
    try {
      // Kalıcılığı BEKLE: yazma başarılıysa kapat. Hata olursa kullanıcı token
      // eklenmiş sanmasın → hatayı göster ve yeniden taramaya izin ver.
      await context.read<VaultCubit>().add(account);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _handled = false;
      _showError('Kaydedilemedi: $e');
    }
  }

  /// Migration QR'ı → controller olayı → UI. Ham metin burada tüketilir ve
  /// hiçbir alana yazılmaz.
  void _handleMigration(String raw) {
    final event = _migrationController.handleRaw(raw);
    switch (event) {
      case MigrationBatchAdded(:final scanned, :final total) ||
            MigrationScanComplete(:final scanned, :final total):
        setState(() {
          _scanned = scanned;
          _total = total;
        });
      case MigrationDuplicateScan():
        _showError('Bu kod zaten okundu');
      case MigrationDifferentBatch():
        unawaited(_askRestart());
      case MigrationInvalidBatch() || MigrationMalformedQr():
        // Neden ayrımı KASITLI olarak gösterilmez (secret'tan türer).
        _showError('Bu QR bir Google Authenticator aktarım kodu değil ya da bozuk.');
      case MigrationScanFull():
        _showError('Bu aktarımda çok fazla hesap var.');
    }
  }

  /// Başka bir dışa aktarmanın QR'ı okundu: birleştirme YAPILMAZ, kullanıcıya
  /// baştan başlamak isteyip istemediği sorulur.
  Future<void> _askRestart() async {
    if (_dialogOpen) return;
    _dialogOpen = true;
    final restart = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: const Text(
            'Bu QR farklı bir dışa aktarmaya ait. Baştan başlansın mı?'),
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
    _dialogOpen = false;
    if (restart == true && mounted) await _restart();
  }

  Future<void> _restart() async {
    _migration?.reset();
    if (mounted) {
      setState(() {
        _scanned = 0;
        _total = 0;
        _preview = null;
        _importError = null;
      });
    }
    await _restartCamera();
  }

  /// Kamerayı durdurup yeniden başlatır.
  ///
  /// GEREKLİ, sadece kozmetik değil: `DetectionSpeed.noDuplicates` Android
  /// tarafında son yayınlanan payload'ı `lastScanned` alanında tutar ve aynı
  /// değeri bir daha yollamaz (mobile_scanner 7.4,
  /// `android/.../MobileScanner.kt`). Bu alan YALNIZCA `start()` ve `stop()`
  /// içinde `null`'lanır → "Baştan başla" sonrası kullanıcı ilk QR'ı yeniden
  /// gösterse tarayıcı onu yutardı. (iOS/macOS tarafında payload
  /// karşılaştırması hiç yok: `noDuplicates` orada yalnız kare hızını kısar, bu
  /// yüzden aynı QR tekrar tekrar gelir — duplicate/diyalog yolları bu
  /// tekrarlara karşı korumalı.)
  Future<void> _restartCamera() async {
    final override = widget.debugRestartCamera;
    if (override != null) {
      await override();
      return;
    }
    try {
      await _controller.stop();
      await _controller.start();
    } catch (_) {
      // Kamera olmayan platform / geçici hata: state zaten sıfırlandı, asıl
      // olan o. Gerçek kamera hatası `errorBuilder` ile zaten görünür.
    }
  }

  Future<void> _stopCamera() async {
    if (widget.debugRestartCamera != null) return;
    try {
      await _controller.stop();
    } catch (_) {
      // Aynı gerekçe: durdurma best-effort.
    }
  }

  /// Toplananları önizlemeye çevirir. Kamera yalnız önizleme GERÇEKTEN
  /// açılacaksa durdurulur.
  Future<void> _showPreview() async {
    final existing = context.read<VaultCubit>().state.accounts;
    final ImportPreview preview;
    try {
      preview = _migrationController.preview(existing: existing);
    } on EmptyImportException {
      _showError('Bu kodlarda içe aktarılacak token bulunamadı.');
      return;
    }
    await _stopCamera();
    if (!mounted) return;
    setState(() {
      _preview = preview;
      _importError = null;
    });
  }

  /// "Bu kadar yeter": eksik tarama meşru bir sonuç, ama sonucu açıkça söyle.
  Future<void> _confirmPartial() async {
    if (_dialogOpen) return;
    _dialogOpen = true;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Bu kadar yeter'),
        content:
            const Text('Yalnız taradığın kodlardaki hesaplar aktarılacak.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Devam'),
          ),
        ],
      ),
    );
    _dialogOpen = false;
    if (go == true && mounted) await _showPreview();
  }

  /// Onay: hepsi TEK `addAll` ile eklenir (tek persist + tek push).
  Future<void> _confirmImport() async {
    final preview = _preview;
    if (preview == null || preview.toAdd.isEmpty) return;
    final vault = context.read<VaultCubit>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _importError = null;
    });
    try {
      await vault.addAll(preview.toAdd);
      _migration?.reset(); // secret'lar artık vault'ta → bellekte tutma
      messenger.showSnackBar(
        SnackBar(content: Text('${preview.addCount} token eklendi')),
      );
      if (mounted) navigator.pop();
    } catch (_) {
      // Kaydedilemedi → sayfa KAPANMAZ, kullanıcı tekrar deneyebilir.
      if (mounted) {
        setState(() => _importError = 'Tokenlar kaydedilemedi — tekrar dene.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(String message) {
    // Async save hatası sonrası kullanıcı ekrandan ayrılmış olabilir → disposed
    // context'e dokunma (add sheet'teki mounted korumasıyla tutarlı).
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final inPreview = _preview != null;
    final page = Scaffold(
      appBar: AppBar(
        title: Text(_total > 0 ? 'Google Authenticator kodunu tara' : 'QR Tara'),
        actions: inPreview
            ? null
            : [
                IconButton(
                  tooltip: 'Flaş',
                  icon: const Icon(Icons.flash_on),
                  onPressed: () => _controller.toggleTorch(),
                ),
                IconButton(
                  tooltip: 'Kamera değiştir',
                  icon: const Icon(Icons.cameraswitch),
                  onPressed: () => _controller.switchCamera(),
                ),
              ],
      ),
      body: SafeArea(
        child: inPreview ? _buildPreview(context) : _buildCamera(context),
      ),
    );

    // Kamera önizlemesi QR'ın kendisini (secret) gösterir, onay adımı da hesap
    // listesini → hassas ekran.
    return SecureScreenScope(child: page);
  }

  Widget _buildPreview(BuildContext context) => ImportPreviewView(
        preview: _preview!,
        headerLabel: 'Google Authenticator',
        headerDetail: '$_scanned/$_total kod',
        error: _importError,
        busy: _busy,
        onConfirm: _confirmImport,
      );

  Widget _buildCamera(BuildContext context) {
    final scanner = widget.debugScannerBuilder?.call(context, _handleRaw) ??
        MobileScanner(
          controller: _controller,
          onDetect: _onDetect,
          onDetectError: (error, _) => _showError('Tarama hatası: $error'),
          errorBuilder: (context, error) => _ScanError(error: error),
          overlayBuilder: (context, _) => const _ScanReticle(),
        );
    if (_total == 0) return scanner;
    return Column(
      children: [
        Expanded(child: scanner),
        _MigrationBand(
          scanned: _scanned,
          total: _total,
          complete: _isComplete,
          onContinue: _showPreview,
          onStopEarly: _confirmPartial,
          onRestart: _restart,
        ),
      ],
    );
  }
}

/// Migration modunun alt bandı: ilerleme + üç çıkış yolu.
class _MigrationBand extends StatelessWidget {
  const _MigrationBand({
    required this.scanned,
    required this.total,
    required this.complete,
    required this.onContinue,
    required this.onStopEarly,
    required this.onRestart,
  });

  final int scanned;
  final int total;
  final bool complete;
  final VoidCallback onContinue;
  final VoidCallback onStopEarly;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('$scanned/$total kod tarandı',
                style: theme.textTheme.titleMedium),
            if (!complete) ...[
              const SizedBox(height: Gap.xs),
              Text(
                'Kalan kodları sırayla okut',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: Gap.md),
            if (complete)
              FilledButton(onPressed: onContinue, child: const Text('Devam'))
            else
              OutlinedButton(
                onPressed: onStopEarly,
                child: const Text('Bu kadar yeter'),
              ),
            TextButton(
              onPressed: onRestart,
              child: const Text('Baştan başla'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Kamera izni reddi / başlatma hatası için kullanıcı dostu durum (EmptyState,
/// Design.md §14.11 — ekrana özgü metin).
class _ScanError extends StatelessWidget {
  final MobileScannerException error;
  const _ScanError({required this.error});

  @override
  Widget build(BuildContext context) {
    final isPermission =
        error.errorCode == MobileScannerErrorCode.permissionDenied;
    return EmptyState(
      icon: Icons.no_photography_outlined,
      title: isPermission ? 'Kamera izni gerekli' : 'Kamera başlatılamadı',
      description: isPermission
          ? 'QR taramak için cihaz ayarlarından kamera iznini etkinleştirin.'
          : 'Kamera açılamadı (${error.errorCode.name}). Lütfen tekrar deneyin.',
    );
  }
}

/// Köşe-rehberli nişangah + yönerge (Design.md: marka rengi, net affordance).
class _ScanReticle extends StatelessWidget {
  const _ScanReticle();

  /// Nişangah çerçeve kenarı.
  static const _frameSize = 240.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: _frameSize,
            height: _frameSize,
            child: CustomPaint(painter: _CornerPainter(scheme.primary)),
          ),
          const SizedBox(height: Gap.xl),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: Gap.lg, vertical: Gap.sm),
            decoration: BoxDecoration(
              // Kamera üstünde okunabilirlik: scrim karartma (Design.md §4 scrim
              // kuralı — scan ekranı tek izinli yüksek-kontrast istisnası §1.2).
              color: scheme.scrim.withValues(alpha: 0.58),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: const Text(
              'QR kodu çerçeveye hizala',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dört köşeye L-şeklinde marka renkli rehber çizer.
class _CornerPainter extends CustomPainter {
  final Color color;
  _CornerPainter(this.color);

  /// Köşe L-rehberinin kol uzunluğu / kalınlığı.
  static const _cornerLen = 32.0;
  static const _cornerStroke = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    const len = _cornerLen;
    final paint = Paint()
      ..color = color
      ..strokeWidth = _cornerStroke
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final w = size.width, h = size.height;
    // Sol üst
    canvas.drawLine(const Offset(0, len), const Offset(0, 0), paint);
    canvas.drawLine(const Offset(0, 0), const Offset(len, 0), paint);
    // Sağ üst
    canvas.drawLine(Offset(w - len, 0), Offset(w, 0), paint);
    canvas.drawLine(Offset(w, 0), Offset(w, len), paint);
    // Sol alt
    canvas.drawLine(Offset(0, h - len), Offset(0, h), paint);
    canvas.drawLine(Offset(0, h), Offset(len, h), paint);
    // Sağ alt
    canvas.drawLine(Offset(w - len, h), Offset(w, h), paint);
    canvas.drawLine(Offset(w, h), Offset(w, h - len), paint);
  }

  @override
  bool shouldRepaint(_CornerPainter old) => old.color != color;
}
