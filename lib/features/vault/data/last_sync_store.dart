/// Token sync cursor kalıcılığı (Faz 3 Patch 3) — `token_sync_cursor_v1`.
///
/// **Cursor = SUNUCU `updated_at`'i** (ISO-8601 UTC string); client saati DEĞİL
/// (tek geçerli sıralama — arrival-order LWW). Catch-up pull `updated_at > cursor`
/// ile yapılır. null/eksik → ilk full pull (yeni cihaz restore). Per-uid namespace
/// (`ViewModeStore` kalıbı); `resetVault` bu anahtarı da siler.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class LastSyncStore {
  static const storageKey = 'token_sync_cursor_v1';

  final FlutterSecureStorage _storage;
  final String _keyPrefix;

  LastSyncStore({FlutterSecureStorage? storage, String keyPrefix = ''})
      : _storage = storage ?? const FlutterSecureStorage(),
        _keyPrefix = keyPrefix;

  String get _key => '$_keyPrefix$storageKey';

  /// Kayıtlı sunucu cursor'u (ISO-8601 UTC); yoksa null (full pull).
  Future<String?> read() => _storage.read(key: _key);

  Future<void> write(String iso) => _storage.write(key: _key, value: iso);

  Future<void> clear() => _storage.delete(key: _key);
}
