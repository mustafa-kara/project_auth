/// "Vault reset owed a server token wipe" marker (security review finding 1, round 2).
///
/// When [resetVault] runs offline (or the server rejects the tombstone), the old
/// remote token rows stay live. This marker records the reset instant (ISO-8601
/// UTC) so the next signed-in unlock can retry — tombstoning only rows older than
/// the reset instant, which leaves a freshly set-up vault's newer tokens intact.
/// Per-uid namespace (mirrors [AttrsDirtyStore]). Set on tombstone failure,
/// cleared on success.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ResetPendingStore {
  static const storageKey = 'token_reset_pending_v1';

  final FlutterSecureStorage _storage;
  final String _keyPrefix;

  ResetPendingStore({FlutterSecureStorage? storage, String keyPrefix = ''})
    : _storage = storage ?? const FlutterSecureStorage(),
      _keyPrefix = keyPrefix;

  String get _key => '$_keyPrefix$storageKey';

  /// Reset instant (ISO-8601 UTC) if a remote tombstone is still owed, else null.
  Future<String?> pendingSince() => _storage.read(key: _key);

  Future<void> setPending(String resetAtIso) =>
      _storage.write(key: _key, value: resetAtIso);

  Future<void> clear() => _storage.delete(key: _key);
}
