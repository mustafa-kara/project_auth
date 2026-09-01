/// Root-JSON fingerprinting: which app produced this file?
///
/// Filled by W1. Order is significant (plan §3.3): our own backup first (its
/// `format` field is explicit), then Aegis, then 2FAS, else unknown. Detection
/// only looks at structural keys — never at secrets.
library;

import 'import_models.dart';

/// Returns the source format of an already decoded root JSON object.
/// Never throws: an unrecognized file is [ImportSource.unknown] so the caller
/// can raise the user-facing `UnsupportedImportFormatException`.
ImportSource detectSource(Map<String, dynamic> json) {
  throw UnimplementedError('W1 fills this');
}
