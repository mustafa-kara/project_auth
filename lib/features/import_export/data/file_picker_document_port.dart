/// `file_picker` backed [DocumentPort] — the only place in the app that talks to
/// the OS document UI.
///
/// Design notes (plan §3.1 / §4.5):
/// - [FileType.any] instead of a `custom` + `json` extension filter: Android's
///   SAF and iOS' UTType tables disagree about `application/json`, and a filter
///   that does not match hides the very file the user came for. The format is
///   validated by content (`ImportService.detect`) rather than by extension.
/// - `withData: true` hands us the bytes directly, so no storage permission and
///   no `path` that Android may refuse. It does NOT avoid a cached copy: the
///   plugin still materialises the picked document in the app's own cache
///   (iOS copies it into `NSTemporaryDirectory()`, Android into
///   `cacheDir/file_picker/`) and never removes it, so [pickJson] shreds that
///   copy itself — see [_clearPickerCache].
/// - `saveFile` leaves a leftover of its own on iOS, in a directory
///   `clearTemporaryFiles()` does NOT touch, so [saveJson] shreds that one —
///   see [FilePickerDocumentPort._shredIosSaveLeftover].
/// - The size ceiling is enforced BEFORE the bytes are handed on, so a huge pick
///   cannot be decoded into a String.
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
  /// [maxBytes] is a UX guard, not a memory guard: the plugin has already read
  /// the whole document into the cached copy and into `bytes` by the time this
  /// method sees it, so the ceiling cannot be applied *before* the bytes exist.
  /// It stops an oversized file from being decoded into a String and parsed.
  ///
  /// The cached copy is cleared on EVERY exit — success, cancel and throw.
  Future<PickedDocument?> _pick({required int maxBytes}) async {
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null; // user cancelled

    final file = result.files.first;
    // `size` is reported by the platform and is cheap to check; the byte payload
    // is checked too because some platforms report 0 for unknown-length streams.
    final bytes = file.bytes;
    if (file.size > maxBytes) {
      throw ImportFileTooLargeException(file.size, maxBytes);
    }
    if (bytes == null) {
      // withData was requested, so a null payload means the platform could not
      // read the document at all (revoked URI, unreadable provider).
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
  /// Verified against file_picker 11.0.3: `FilePicker.clearTemporaryFiles()` is
  /// a static that forwards to the platform's `clear` channel call, implemented
  /// on Android and iOS only. Every failure is swallowed — desktop/web throw
  /// `UnimplementedError` from the platform interface, and a housekeeping error
  /// must never turn a completed import into a user-facing failure.
  static Future<void> _clearPickerCache() async {
    try {
      await FilePicker.clearTemporaryFiles();
    } catch (_) {
      // Best effort; see doc comment.
    }
  }

  @override
  Future<bool> saveJson({
    required String fileName,
    required Uint8List bytes,
  }) async {
    // `bytes` is mandatory on Android/iOS (the plugin writes the file itself) and
    // is written at the chosen path on desktop — one call covers every platform,
    // so no share_plus fallback is needed. It is NOT copy-free on iOS, though;
    // see [_shredIosSaveLeftover].
    String? path;
    try {
      path = await FilePicker.saveFile(
        fileName: fileName,
        type: FileType.any,
        bytes: bytes,
      );
      return path != null; // null = user cancelled the save dialog
    } finally {
      await _shredIosSaveLeftover(fileName: fileName, savedPath: path);
    }
  }

  /// Shreds the copy `saveFile` leaves in the app's iOS Documents directory.
  ///
  /// Verified against file_picker 11.0.3
  /// (`ios/file_picker/Sources/file_picker/FilePickerPlugin.m`): the `save`
  /// channel call lands in `saveFileWithName:fileType:initialDirectory:bytes:`,
  /// which builds its destination as
  /// `URLsForDirectory:NSDocumentDirectory ...[0]` +
  /// `URLByAppendingPathComponent:fileName` — the caller's [fileName]
  /// verbatim — writes the payload there, and only THEN presents
  /// `UIDocumentPickerViewController` in `UIDocumentPickerModeExportToService`,
  /// i.e. the picker COPIES it to wherever the user chose. Neither
  /// `documentPicker:didPickDocumentsAtURLs:` (which just returns
  /// `urls[0].path`) nor `documentPickerWasCancelled:` removes the source, and
  /// `FilePickerUtils.clearTemporaryFiles` only walks `NSTemporaryDirectory()`
  /// — so on iOS the whole backup file survives in Documents, which is part of
  /// the iCloud/iTunes device backup.
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
