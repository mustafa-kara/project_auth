/// key_attributes "kirli" (sunucuya henüz yazılamadı) marker'ı (Faz 3 Patch 3 — Adım K).
///
/// changePassword/recovery-new-password sonrası sunucu sarmalını GÜNCELLEME ağ hatasına
/// düşerse marker SET kalır → bir sonraki unlock'ta dirty-replay ile yeniden denenir
/// (gerçek retry; `_backfillRemote` insert-once guard'ı bunu yapamaz). Başarıda CLEAR.
/// Per-uid namespace (`ViewModeStore` kalıbı); `resetVault` bu anahtarı da siler.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AttrsDirtyStore {
  static const storageKey = 'attrs_dirty_v1';

  final FlutterSecureStorage _storage;
  final String _keyPrefix;

  AttrsDirtyStore({FlutterSecureStorage? storage, String keyPrefix = ''})
    : _storage = storage ?? const FlutterSecureStorage(),
      _keyPrefix = keyPrefix;

  String get _key => '$_keyPrefix$storageKey';

  /// Sunucuya yazılmamış key_attributes değişikliği var mı.
  Future<bool> isDirty() async => (await _storage.read(key: _key)) == 'true';

  Future<void> setDirty() => _storage.write(key: _key, value: 'true');

  Future<void> clear() => _storage.delete(key: _key);
}
