/// QR tarama ekranı — `mobile_scanner` ile kamera taraması + `otpauth://` tespiti.
///
/// İlk geçerli `otpauth://` QR'ı yakalandığında token vault'a eklenir ve ekran
/// kapanır. Geçersiz QR / parse hatası kullanıcıya gösterilir, tarama sürer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/otp/otp_account.dart';
import '../../../core/otp/otpauth_uri.dart';
import '../../../core/ui/tokens.dart';
import '../../vault/presentation/bloc/vault_cubit.dart';

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );

  /// İlk başarılı yakalamadan sonra tekrar işlemeyi (ve çift ekleme/çift pop'u)
  /// engeller. Kamera akışı birden çok kare yollayabilir.
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) return;

    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
    if (raw == null) return;

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('QR Tara'),
        actions: [
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
      body: MobileScanner(
        controller: _controller,
        onDetect: _onDetect,
        onDetectError: (error, _) => _showError('Tarama hatası: $error'),
        errorBuilder: (context, error) => _ScanError(error: error),
        overlayBuilder: (context, _) => const _ScanReticle(),
      ),
    );
  }
}

/// Kamera izni reddi / başlatma hatası için kullanıcı dostu durum.
class _ScanError extends StatelessWidget {
  final MobileScannerException error;
  const _ScanError({required this.error});

  @override
  Widget build(BuildContext context) {
    final isPermission =
        error.errorCode == MobileScannerErrorCode.permissionDenied;
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.no_photography,
                size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: Gap.lg),
            Text(
              isPermission
                  ? 'Kamera izni verilmedi. QR taramak için ayarlardan kamera '
                      'iznini etkinleştir.'
                  : 'Kamera başlatılamadı: ${error.errorCode.name}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

/// Köşe-rehberli nişangah + yönerge (Design.md: marka rengi, net affordance).
class _ScanReticle extends StatelessWidget {
  const _ScanReticle();

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return IgnorePointer(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 240,
            height: 240,
            child: CustomPaint(painter: _CornerPainter(accent)),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(8),
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

  @override
  void paint(Canvas canvas, Size size) {
    const len = 32.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4
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
