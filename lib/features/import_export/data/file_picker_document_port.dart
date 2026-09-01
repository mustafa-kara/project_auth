/// `file_picker` backed [DocumentPort] — the only place in the app that talks to
/// the OS document UI.
///
/// Design notes (plan §3.1 / §4.5):
/// - [FileType.any] instead of a `custom` + `json` extension filter: Android's
///   SAF and iOS' UTType tables disagree about `application/json`, and a filter
///   that does not match hides the very file the user came for. The format is
///   validated by content (`ImportService.detect`) rather than by extension.
/// - `withData: true` hands us the bytes directly, so no storage permission,
///   no cached copy to clean up, and no `path` that Android may refuse.
/// - The size ceiling is enforced BEFORE the bytes are handed on, so a huge pick
///   cannot be decoded into a String.
///
/// SECURITY: opening either dialog backgrounds the app (Android emits `paused`),
/// which would normally wipe the master key. Callers MUST wrap every call in
/// `VaultLockCubit.beginSystemFileFlow()` / `endSystemFileFlow()` (plan §3.2).
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../domain/file_port.dart';
import '../domain/import_exceptions.dart';

class FilePickerDocumentPort implements DocumentPort {
  const FilePickerDocumentPort();

  @override
  Future<PickedDocument?> pickJson({required int maxBytes}) async {
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
  Future<bool> saveJson({
    required String fileName,
    required Uint8List bytes,
  }) async {
    // `bytes` is mandatory on Android/iOS (the plugin writes the file itself) and
    // is written at the chosen path on desktop — one call covers every platform,
    // so no share_plus/path_provider fallback and no temp file to shred.
    final path = await FilePicker.saveFile(
      fileName: fileName,
      type: FileType.any,
      bytes: bytes,
    );
    return path != null; // null = user cancelled the save dialog
  }
}
