/// Platform file-picking port, kept out of domain/service code so import/export
/// logic stays pure Dart and host-testable.
///
/// Implemented by W3 (`data/file_picker_document_port.dart`). Opening a system
/// picker backgrounds the app on Android, so every call site must be wrapped in
/// `VaultLockCubit.beginSystemFileFlow/endSystemFileFlow` (plan §3.2).
library;

import 'dart:typed_data';

/// A document the user picked, already read into memory.
class PickedDocument {
  final String name;
  final Uint8List bytes;
  const PickedDocument(this.name, this.bytes);
}

abstract interface class DocumentPort {
  /// Opens the system picker for a JSON document. Returns null when the user
  /// cancels. Throws `ImportFileTooLargeException` when the file exceeds
  /// [maxBytes] (checked before the bytes are handed over).
  Future<PickedDocument?> pickJson({required int maxBytes});

  /// Writes [bytes] to a user-chosen location. Returns false when the user
  /// cancels; throws only on a platform failure.
  Future<bool> saveJson({required String fileName, required Uint8List bytes});
}
