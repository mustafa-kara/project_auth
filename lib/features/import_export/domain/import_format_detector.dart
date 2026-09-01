/// Root-JSON fingerprinting: which app produced this file?
///
/// Filled by W1. Order is significant (plan §3.3): our own backup first (its
/// `format` field is explicit), then Aegis, then 2FAS, else unknown. Detection
/// only looks at structural keys — never at secrets.
library;

import 'import_models.dart';

/// Mirror of `BackupService.formatId`. Deliberately duplicated as a literal so
/// this file stays pure Dart: `backup_service.dart` pulls in `CryptoService`
/// (libsodium plugin) and importing it here would make the detector unusable
/// inside `Isolate.run` and on the host test VM.
const String _projectauthBackupFormatId = 'projectauth-backup';

/// Returns the source format of an already decoded root JSON object.
/// Never throws: an unrecognized file is [ImportSource.unknown] so the caller
/// can raise the user-facing `UnsupportedImportFormatException`.
///
/// Fingerprints, in the order they are tested:
/// 1. `format == 'projectauth-backup'` — our own envelope names itself, so it
///    wins even if a future version also carried `db`/`services` keys.
/// 2. `db` **and** `header` — Aegis. Both are required: `header` alone appears
///    in unrelated files and `db` alone is too generic. The value types are not
///    inspected here on purpose — an encrypted Aegis export has `db` as a
///    String, and it must still be detected as Aegis so the parser can raise
///    `EncryptedSourceException` rather than "unsupported format".
/// 3. `services` **or** `servicesEncrypted` — 2FAS. Same reasoning: an
///    encrypted 2FAS export carries an empty `services` list plus the
///    `servicesEncrypted` blob, and either key is enough to claim the file.
ImportSource detectSource(Map<String, dynamic> json) {
  if (json['format'] == _projectauthBackupFormatId) {
    return ImportSource.projectauthBackup;
  }
  if (json.containsKey('db') && json.containsKey('header')) {
    return ImportSource.aegis;
  }
  if (json.containsKey('services') || json.containsKey('servicesEncrypted')) {
    return ImportSource.twofas;
  }
  return ImportSource.unknown;
}
