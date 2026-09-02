/// Platform file-picking port, kept out of domain/service code so import/export
/// logic stays pure Dart and host-testable.
///
/// Implemented by `data/file_picker_document_port.dart`. Opening a system
/// picker backgrounds the app on Android, so every call site must be wrapped in
/// `VaultLockCubit.beginSystemFileFlow/endSystemFileFlow` (plan §3.2).
///
/// Phase 5 Patch 3 adds [DocumentPort.pickImage] and
/// [DocumentPort.clearPickerCache] for "read a QR from a saved screenshot";
/// W3 fills their implementation.
library;

import 'dart:typed_data';

/// A document the user picked, already read into memory.
class PickedDocument {
  final String name;
  final Uint8List bytes;
  const PickedDocument(this.name, this.bytes);
}

/// An image the user picked, referenced by PATH rather than by bytes.
///
/// The QR decoder (`mobile_scanner`'s `analyzeImage`) takes a file path and
/// does the decoding on the platform side, so pulling a multi-megapixel photo
/// into a Dart [Uint8List] first would only waste memory.
///
/// [path] points at the picker's own cached COPY of the image, inside the app
/// sandbox — never at the user's original in the photo library. Nothing in this
/// app writes to or deletes the original.
///
/// SECURITY: that cached copy is a plaintext image of a QR code, i.e. of a live
/// TOTP seed, sitting in a directory the OS clears on its own schedule (maybe
/// never). The caller MUST shred it in a `finally`
/// (`DocumentPort.clearPickerCache`, plus a zero-fill + delete of [path]).
class PickedImage {
  /// Absolute path of the picker's cached copy.
  final String path;

  /// Display name as the OS reported it. For UI/logging shape only — never
  /// interpolated into an error the user sees, since a file name can be
  /// arbitrary text from another app.
  final String name;

  /// Size the platform reported for the pick, in bytes.
  final int sizeBytes;

  const PickedImage({
    required this.path,
    required this.name,
    required this.sizeBytes,
  });
}

abstract interface class DocumentPort {
  /// Opens the system picker for a JSON document. Returns null when the user
  /// cancels. Throws `ImportFileTooLargeException` when the file exceeds
  /// [maxBytes] (checked before the bytes are handed over).
  Future<PickedDocument?> pickJson({required int maxBytes});

  /// Writes [bytes] to a user-chosen location. Returns false when the user
  /// cancels; throws only on a platform failure.
  Future<bool> saveJson({required String fileName, required Uint8List bytes});

  /// Opens the system picker for a single IMAGE. Returns null when the user
  /// cancels. Throws `ImportFileTooLargeException` when the image exceeds
  /// [maxBytes] (checked from the reported size, before anything is read).
  ///
  /// Unlike [pickJson] this does NOT clear the picker cache on the way out —
  /// the returned [PickedImage.path] has to stay readable long enough for the
  /// decoder to run. The caller owns the cleanup and MUST call
  /// [clearPickerCache] in a `finally` once decoding is done.
  Future<PickedImage?> pickImage({required int maxBytes});

  /// Deletes the plaintext copies the picker left in the app cache.
  ///
  /// Best effort by contract: implementations swallow every failure, because
  /// housekeeping must never turn a completed import into a user-facing error.
  Future<void> clearPickerCache();
}
