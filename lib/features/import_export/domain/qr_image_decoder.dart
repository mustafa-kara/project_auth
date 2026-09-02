/// Seam for "read the QR out of an image the user already saved" (plan §5 D5).
///
/// The scan screen only ever sees a [QrImageDecoder] function, so every test
/// around the image-import flow runs on the host VM with a closure — no camera,
/// no ML Kit, no platform channel. The single real implementation
/// (`data/mobile_scanner_qr_decoder.dart`, filled by W3) is a thin adapter over
/// `MobileScannerController.analyzeImage`, which does NOT require an
/// initialized camera or a camera permission.
///
/// SECURITY: a decoded string IS a live secret (`otpauth://...?secret=...` or a
/// Google migration payload). It is parsed and dropped; it is never logged,
/// never put on the clipboard and never interpolated into a message shown to
/// the user. The exceptions here carry NO payload for the same reason.
library;

/// Decodes every QR code found in the image at [path].
///
/// Returns the raw strings in the order the platform reported them, and an
/// EMPTY list when the image simply has no QR in it — that is a normal outcome
/// ("Bu görüntüde QR kod bulunamadı."), not an error.
///
/// Throws [QrImageUnsupportedException] where image analysis does not exist,
/// and [QrImageUnreadableException] when the file could not be decoded as an
/// image at all.
typedef QrImageDecoder = Future<List<String>> Function(String path);

/// Ceilings for the image-import path, kept next to the decoder so the picker
/// and the scan screen agree on one number.
class QrImageLimits {
  const QrImageLimits._();

  /// Largest image accepted, checked from the size the picker reports BEFORE
  /// anything is read or copied.
  ///
  /// 16 MiB comfortably covers a modern phone screenshot or a 48MP photo of a
  /// printed QR, while keeping a hostile "image" from being handed to the
  /// platform decoder. The user-facing ceiling is stated in MB
  /// ("en fazla 16 MB") — close enough for a limit message, and the exact byte
  /// count is what the code enforces.
  static const int maxBytes = 16 * 1024 * 1024;
}

/// Image analysis is unavailable on this platform or build.
///
/// `mobile_scanner`'s `analyzeImage` throws on the web, and on the iOS
/// Simulator the Vision-backed path is not supported (see the plugin's
/// `MobileScannerPlugin.swift`). Distinct from [QrImageUnreadableException]
/// because the UI must tell the user "this device cannot do it" rather than
/// "your image was bad" — retrying with another picture would not help.
class QrImageUnsupportedException implements Exception {
  const QrImageUnsupportedException();
  @override
  String toString() =>
      'QrImageUnsupportedException: image analysis unavailable on this platform';
}

/// The file was picked but could not be decoded as an image (truncated,
/// unsupported codec, revoked URI, cache reclaimed mid-flight).
///
/// Carries no path and no platform message: a file name is arbitrary text from
/// another app, and a platform error string could quote file content.
class QrImageUnreadableException implements Exception {
  const QrImageUnreadableException();
  @override
  String toString() => 'QrImageUnreadableException: image could not be decoded';
}
