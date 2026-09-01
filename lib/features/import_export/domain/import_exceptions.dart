/// File-level import/restore failures.
///
/// Thrown by W1 (detector/parsers) and W2 (backup service); W3 maps each type to
/// its Turkish UI message. Per-entry problems are NOT exceptions — they become
/// `SkippedEntry` records so one bad row cannot drop the whole file.
///
/// SECURITY: messages are developer-facing and must never embed a secret, a
/// password or raw file content.
library;

import 'import_models.dart';

/// File exceeds `ImportService.maxBytes`; rejected before decoding so a huge
/// pick cannot blow up the heap.
class ImportFileTooLargeException implements Exception {
  final int bytes;
  final int max;
  const ImportFileTooLargeException(this.bytes, this.max);
  @override
  String toString() => 'ImportFileTooLargeException: $bytes bytes exceeds $max';
}

/// Not valid UTF-8, not valid JSON, or the root is not a JSON object.
class MalformedImportFileException implements Exception {
  final String message;
  const MalformedImportFileException([this.message = 'not a readable JSON backup']);
  @override
  String toString() => 'MalformedImportFileException: $message';
}

/// Root JSON parsed, but matched no known fingerprint ([ImportSource.unknown]).
class UnsupportedImportFormatException implements Exception {
  const UnsupportedImportFormatException();
  @override
  String toString() => 'UnsupportedImportFormatException: unrecognized backup format';
}

/// The source file is password-protected in its own app (Aegis `header.slots`,
/// 2FAS `servicesEncrypted`). We deliberately do not implement foreign KDFs —
/// the user must re-export unencrypted. [source] drives the UI guidance.
class EncryptedSourceException implements Exception {
  final ImportSource source;
  const EncryptedSourceException(this.source);
  @override
  String toString() => 'EncryptedSourceException: ${source.name} export is encrypted';
}

/// Format recognized but it yielded zero importable accounts.
class EmptyImportException implements Exception {
  const EmptyImportException();
  @override
  String toString() => 'EmptyImportException: no importable tokens in file';
}

/// Backup decryption failed. Wrong password and tampered ciphertext are
/// indistinguishable by design (AEAD), so both surface as this one type.
class WrongBackupPasswordException implements Exception {
  const WrongBackupPasswordException();
  @override
  String toString() => 'WrongBackupPasswordException: wrong password or corrupted backup';
}

/// Backup envelope version is newer than `BackupService.supportedVersion`.
/// Refused rather than best-effort parsed: unknown fields may carry meaning.
class UnsupportedBackupVersionException implements Exception {
  final int version;
  const UnsupportedBackupVersionException(this.version);
  @override
  String toString() => 'UnsupportedBackupVersionException: version $version';
}
