/// `file_picker` backed [DocumentPort] — the only place in the app that talks to
/// the OS document UI.
///
/// Design notes (plan §3.1 / §4.5):
/// - [FileType.any] instead of a `custom` + `json` extension filter: Android's
///   SAF and iOS' UTType tables disagree about `application/json`, and a filter
///   that does not match hides the very file the user came for. The format is
///   validated by content (`ImportService.detect`) rather than by extension.
/// - `pickFile()` (file_picker 12) returns a single [PlatformFile] whose bytes
///   are read on demand via `readAsBytes()`. The read is served from the app's
///   OWN cached copy of the document — the plugin materialises every pick there
///   (iOS copies it into `NSTemporaryDirectory()`, Android into
///   `cacheDir/file_picker/`) and never removes it — so no storage permission
///   and no `path` the OS may refuse are needed, but a PLAINTEXT copy is left
///   behind and [pickJson] shreds it — see [_clearPickerCache].
/// - `saveFile` leaves a leftover of its own on iOS; [saveJson] shreds it —
///   see [FilePickerDocumentPort._shredIosSaveLeftover].
/// - The size ceiling is enforced BEFORE the bytes are read, so a huge pick is
///   never materialised in memory nor decoded into a String.
///
/// SECURITY: opening either dialog backgrounds the app (Android emits `paused`),
/// which would normally wipe the master key. Callers MUST wrap every call in
/// `VaultLockCubit.beginSystemFileFlow()` / `endSystemFileFlow()` (plan §3.2).
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
// `Uint8List` dahil: `dart:typed_data`'yı da re-export eder.
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/file_port.dart';
import '../domain/import_exceptions.dart';

class FilePickerDocumentPort implements DocumentPort {
  /// [documentsDir] and [isIOS] are seams for [_shredIosSaveLeftover]: the
  /// shredder must be exercised against a real directory in tests, where
  /// `path_provider`'s platform channel is absent and `Platform.isIOS` is
  /// false. Production leaves both null.
  const FilePickerDocumentPort({
    @visibleForTesting Future<Directory> Function()? documentsDir,
    @visibleForTesting bool Function()? isIOS,
  })  : _documentsDir = documentsDir,
        _isIOS = isIOS;

  final Future<Directory> Function()? _documentsDir;
  final bool Function()? _isIOS;

  /// Zero-fill block size: a backup is bounded, but there is no reason to
  /// allocate the whole thing at once.
  static const int _shredChunk = 64 * 1024;

  /// Picks one document and returns its bytes.
  ///
  /// [maxBytes] is checked twice. `length()` answers from the size the platform
  /// reported for the pick and only stats the cached copy as a fallback, so it
  /// is cheap and rejects an oversized document BEFORE `readAsBytes()` pulls it
  /// into memory. The byte payload is re-checked because some platforms report
  /// 0 for unknown-length streams; that second check is what stops an oversized
  /// file from being decoded into a String and parsed.
  ///
  /// The cached copy is cleared on EVERY exit — success, cancel and throw.
  Future<PickedDocument?> _pick({required int maxBytes}) async {
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null) return null; // user cancelled

    final reportedSize = await file.length();
    if (reportedSize > maxBytes) {
      throw ImportFileTooLargeException(reportedSize, maxBytes);
    }

    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      // The read is served from the plugin's own cached copy, so a failure here
      // means the platform could not produce the document at all (revoked URI,
      // unreadable provider, cache already reclaimed).
      throw const MalformedImportFileException('file contents unavailable');
    }
    if (bytes.length > maxBytes) {
      throw ImportFileTooLargeException(bytes.length, maxBytes);
    }
    return PickedDocument(file.name, bytes);
  }

  @override
  Future<PickedDocument?> pickJson({required int maxBytes}) async {
    try {
      return await _pick(maxBytes: maxBytes);
    } finally {
      // The bytes are already in memory, so the plugin's cached copy is dead
      // weight — and it is a PLAINTEXT copy of the user's secrets sitting in a
      // directory the OS clears on its own schedule (i.e. maybe never).
      await _clearPickerCache();
    }
  }

  /// Deletes the plaintext copy `file_picker` leaves in the app cache.
  ///
  /// Verified against file_picker 12.1.3: `FilePicker.clearTemporaryFiles()` is
  /// a static that forwards to `FilePickerPlatform.instance.clearTemporaryFiles`,
  /// which only `android_file_picker` and `file_picker_darwin` implement (both
  /// as the `clear` call on the unchanged `miguelruivo.flutter.plugins.filepicker`
  /// channel; the interface's own default is a no-op, so desktop and web simply
  /// do nothing). Every failure is swallowed — a housekeeping error must never
  /// turn a completed import into a user-facing failure.
  static Future<void> _clearPickerCache() async {
    try {
      await FilePicker.clearTemporaryFiles();
    } catch (_) {
      // Best effort; see doc comment.
    }
  }

  /// Phase 5 Patch 3 — image pick for "read a QR from a saved screenshot".
  ///
  /// [FileType.image] here (rather than [FileType.any] as in [pickJson]) because
  /// the destination is a platform IMAGE decoder, not a content sniffer: on iOS
  /// this is what routes the pick through `file_picker_darwin`'s PHPicker,
  /// which hands over one photo WITHOUT the app holding photo-library access.
  ///
  /// No `withData`/compression knobs are passed: file_picker 12's `pickFile`
  /// reads bytes lazily (`PlatformFile.readAsBytes()`) so nothing is
  /// materialised by picking, and `compressionQuality` defaults to 0, i.e. the
  /// image is handed over untouched — re-encoding a screenshot is exactly what
  /// would smear a dense QR into an undecodable one.
  ///
  /// The size ceiling is checked from `length()`, which answers from the size
  /// the platform reported, so an oversized pick is rejected before anything is
  /// read.
  ///
  /// Unlike [pickJson] the picker cache is deliberately NOT cleared here: the
  /// returned path must stay readable until the decode finishes. The caller
  /// owns that cleanup ([clearPickerCache] + [shredCachedCopy]) in a `finally`.
  @override
  Future<PickedImage?> pickImage({required int maxBytes}) async {
    final file = await FilePicker.pickFile(type: FileType.image);
    if (file == null) return null; // user cancelled

    final reportedSize = await file.length();
    if (reportedSize > maxBytes) {
      throw ImportFileTooLargeException(reportedSize, maxBytes);
    }

    // `PlatformFile.path` is null when the pick is not on local disk (web
    // blob/data URIs). The decoder takes a path and nothing else, so there is
    // no degraded mode to fall back to.
    final path = file.path;
    if (path == null) {
      throw const MalformedImportFileException('picked image has no local path');
    }
    return PickedImage(
      path: path,
      name: file.name,
      sizeBytes: reportedSize,
    );
  }

  /// Public face of [_clearPickerCache], for callers that own the cache
  /// lifetime themselves (see [pickImage]).
  @override
  Future<void> clearPickerCache() => _clearPickerCache();

  /// Zero-fills and unlinks ONE cached pick, given its path.
  ///
  /// [clearPickerCache] alone would unlink the file without overwriting it,
  /// which leaves the pixels of a QR — i.e. of a live TOTP seed — recoverable
  /// on the block device. This is the same treatment [_shredIosSaveLeftover]
  /// gives an export leftover, exposed because [pickImage]'s caller, not this
  /// port, decides when the file has served its purpose.
  ///
  /// Operates ONLY on the picker's own cached copy inside the app sandbox. The
  /// user's original in the photo library is never touched — the plugin does
  /// not hand that path over, and the app declares no write access to it.
  ///
  /// SYNCHRONOUS on purpose, unlike [_zeroFill]'s async twin: this must finish
  /// BEFORE [clearPickerCache] unlinks the same file (an unlink with no
  /// overwrite is exactly what it is guarding against) and before the screen
  /// that owns the flow can be torn down mid-await. The cost is bounded by
  /// `QrImageLimits.maxBytes` and paid once, right after a system-picker
  /// round-trip the user just sat through.
  ///
  /// Best effort: every failure is swallowed, for the same reason as
  /// [_clearPickerCache].
  static void shredCachedCopy(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return;
      _zeroFillSync(file);
      file.deleteSync();
    } catch (_) {
      // Best effort; see doc comment.
    }
  }

  /// [_zeroFill]'s synchronous twin — see [shredCachedCopy] for why.
  static void _zeroFillSync(File file) {
    final length = file.lengthSync();
    if (length <= 0) return;
    final raf = file.openSync(mode: FileMode.writeOnlyAppend);
    try {
      raf.setPositionSync(0);
      final zeros = Uint8List(length < _shredChunk ? length : _shredChunk);
      var written = 0;
      while (written < length) {
        final remaining = length - written;
        final take = remaining < zeros.length ? remaining : zeros.length;
        raf.writeFromSync(zeros, 0, take);
        written += take;
      }
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
  }

  @override
  Future<bool> saveJson({
    required String fileName,
    required Uint8List bytes,
  }) async {
    // `fileName` and `bytes` are required on every platform in file_picker 12:
    // Android/iOS hand the payload to the native side, desktop writes it at the
    // chosen path — one call covers every platform, so no share_plus fallback is
    // needed. It is NOT copy-free on iOS, though; see [_shredIosSaveLeftover].
    Uri? saved;
    try {
      saved = await FilePicker.saveFile(fileName: fileName, bytes: bytes);
      return saved != null; // null = user cancelled the save dialog
    } finally {
      await _shredIosSaveLeftover(
        fileName: fileName,
        savedPath: _localPath(saved),
      );
    }
  }

  /// The on-disk path behind a `saveFile` result, or null when the destination
  /// is not a local file (`content:` on Android SAF, `blob:`/`data:` on web).
  ///
  /// file_picker 12 returns a [Uri] where 11.x returned a bare path string;
  /// [Uri.toFilePath] throws on any other scheme, hence the guard.
  static String? _localPath(Uri? uri) =>
      (uri != null && uri.scheme == 'file') ? uri.toFilePath() : null;

  /// Shreds a copy of the export left in the app's iOS Documents directory.
  ///
  /// HISTORY — this guarded a real leak in file_picker 11.0.3
  /// (`ios/file_picker/Sources/file_picker/FilePickerPlugin.m`): its `save` call
  /// wrote the payload to `NSDocumentDirectory/<fileName>` before exporting it
  /// through `UIDocumentPickerViewController`, removed it on no path, and was
  /// out of reach of `clearTemporaryFiles()` (which walks `NSTemporaryDirectory()`
  /// only) — so the encrypted backup survived in Documents, which IS part of the
  /// iCloud/iTunes device backup.
  ///
  /// STATUS on file_picker 12 — re-verified against `file_picker_darwin` 1.0.4
  /// (`darwin/.../Sources/file_picker_darwin/IOSFilePickerHandler.swift`,
  /// `saveFile(_:)`): the staging file is now built from
  /// `URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)`,
  /// i.e. Documents is no longer touched, and `NSTemporaryDirectory()` is both
  /// excluded from device backups and reclaimed by the OS. The leftover is still
  /// never deleted after the export, but it no longer lands anywhere that leaves
  /// the device.
  ///
  /// This shredder is KEPT as defence in depth rather than reduced to a no-op:
  /// it costs one `exists()` on a directory that should hold no such file, and
  /// it is the only thing standing between a future upstream change of that
  /// destination and a plaintext-path regression that nothing else would catch.
  ///
  /// Best effort by design: overwrite in place with zeros, then unlink, and
  /// swallow every failure — housekeeping must not turn a completed export into
  /// a user-facing error, and this is defence in depth on top of the backup
  /// being encrypted already.
  ///
  /// No-op off iOS: Android writes through the SAF stream and desktop writes
  /// straight to the chosen path, so nothing is left behind there.
  Future<void> _shredIosSaveLeftover({
    required String fileName,
    required String? savedPath,
  }) async {
    final onIOS = _isIOS ?? _defaultIsIOS;
    if (!onIOS()) return;
    try {
      final dir = await (_documentsDir ?? getApplicationDocumentsDirectory)();
      final leftover =
          File('${dir.path}${Platform.pathSeparator}$fileName');
      // Paranoia: the app declares neither `UIFileSharingEnabled` nor
      // `LSSupportsOpeningDocumentsInPlace`, so its Documents directory is not
      // browsable in Files and the chosen destination can never BE the
      // leftover — but if that ever changes, do not delete the user's export.
      if (savedPath != null && savedPath == leftover.path) return;
      if (!await leftover.exists()) return;
      await _zeroFill(leftover);
      await leftover.delete();
    } catch (_) {
      // Best effort; see doc comment.
    }
  }

  static bool _defaultIsIOS() => !kIsWeb && Platform.isIOS;

  /// Overwrites [file] with zeros without truncating it first, so the existing
  /// bytes are rewritten wherever the filesystem lets them be.
  static Future<void> _zeroFill(File file) async {
    final length = await file.length();
    if (length <= 0) return;
    // `writeOnlyAppend` opens without truncating; the position is then reset to
    // 0 so the bytes are overwritten rather than appended to.
    final raf = await file.open(mode: FileMode.writeOnlyAppend);
    try {
      await raf.setPosition(0);
      final zeros =
          Uint8List(length < _shredChunk ? length : _shredChunk);
      var written = 0;
      while (written < length) {
        final remaining = length - written;
        final take = remaining < zeros.length ? remaining : zeros.length;
        await raf.writeFrom(zeros, 0, take);
        written += take;
      }
      await raf.flush();
    } finally {
      await raf.close();
    }
  }
}
