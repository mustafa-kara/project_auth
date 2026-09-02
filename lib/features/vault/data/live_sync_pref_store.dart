/// Canlı senkron (Realtime) tercihi kalıcılığı (Faz 3 Patch 3) — `live_sync_enabled_v1`.
///
/// Varsayılan **false** (muhafazakâr; kullanıcı Settings'ten açıkça açar). Kapalıyken
/// bile unlock'ta catch-up pull + push çalışır (sync devam eder; yalnız canlı abonelik
/// kapanır). Per-uid namespace (`ViewModeStore` kalıbı); `resetVault` bu anahtarı da siler.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class LiveSyncPrefStore {
  static const storageKey = 'live_sync_enabled_v1';

  final FlutterSecureStorage _storage;
  final String _keyPrefix;

  LiveSyncPrefStore({FlutterSecureStorage? storage, String keyPrefix = ''})
    : _storage = storage ?? const FlutterSecureStorage(),
      _keyPrefix = keyPrefix;

  String get _key => '$_keyPrefix$storageKey';

  /// Kayıtlı tercih; yoksa varsayılan **false** (canlı kapalı).
  Future<bool> read() async => (await _storage.read(key: _key)) == 'true';

  Future<void> write(bool enabled) =>
      _storage.write(key: _key, value: enabled ? 'true' : 'false');
}
