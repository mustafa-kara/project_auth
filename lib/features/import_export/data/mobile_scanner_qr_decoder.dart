/// The one real implementation of [QrImageDecoder]: `mobile_scanner`'s image
/// analysis, wrapped so nothing above it ever sees a plugin type (plan §5 D5).
///
/// WHY THE PLATFORM INTERFACE AND NOT A CONTROLLER: `analyzeImage` is a pure
/// path-in / barcodes-out call — `MobileScannerController.analyzeImage` only
/// forwards to `MobileScannerPlatform.instance` and, unlike the camera calls,
/// does NOT go through `_throwIfNotInitialized` (mobile_scanner 7.4,
/// `mobile_scanner_controller.dart:314`). Building a controller here just to
/// forward would allocate a second `ValueNotifier` over the SAME platform
/// singleton the scan screen's own controller is driving, and disposing it
/// would tear down the live camera session. So this talks to the platform
/// instance directly: no camera, no permission, no lifecycle.
///
/// SECURITY: the decoded strings are live secrets. They are returned to the
/// caller and nothing else — never logged, never cached, never put on the
/// clipboard. The two exceptions carry NO platform message for the same reason
/// (a plugin error string can quote file content or a file name written by
/// another app).
library;

import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../domain/qr_image_decoder.dart';

/// Adapter over `MobileScannerPlatform.analyzeImage`, shaped as a
/// [QrImageDecoder] (`const MobileScannerQrDecoder().call`).
class MobileScannerQrDecoder {
  const MobileScannerQrDecoder();

  /// Decodes every QR code in the image at [path].
  ///
  /// Only [BarcodeFormat.qrCode] is requested: the app has no use for the other
  /// symbologies and a narrower request keeps the platform decoder from
  /// reporting, say, a barcode printed next to the QR.
  Future<List<String>> call(String path) async {
    final BarcodeCapture? capture;
    try {
      capture = await MobileScannerPlatform.instance.analyzeImage(
        path,
        formats: const [BarcodeFormat.qrCode],
      );
    } on UnsupportedError {
      // iOS Simulator and web: the plugin says so explicitly. Retrying with
      // another image would not help, hence a distinct exception. Covers the
      // platform interface's own `UnimplementedError` default too (a subtype),
      // i.e. a platform with no image analysis at all.
      throw const QrImageUnsupportedException();
    } on MissingPluginException {
      // No native side registered (host tests, a stripped build).
      throw const QrImageUnsupportedException();
    } catch (_) {
      // `MobileScannerBarcodeException` and anything unforeseen collapse into
      // one outcome: the file could not be read as an image. The cause is not
      // disclosed — see the library note.
      throw const QrImageUnreadableException();
    }
    if (capture == null) return const <String>[];
    return <String>[
      for (final barcode in capture.barcodes)
        if (barcode.rawValue case final String raw when raw.isNotEmpty) raw,
    ];
  }
}
