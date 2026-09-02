/// Vault görünüm tercihi (kart ↔ liste) kalıcılığı — `vault_view_mode_v1`.
///
/// Design.md §4: varsayılan spacious kart; tercih `flutter_secure_storage`'da
/// saklanır (yeni SharedPreferences bağımlılığı yok, mevcut storage ile tutarlı;
/// `resetVault()` bu anahtarı da siler).
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum VaultViewMode { card, list }

class ViewModeStore {
  static const storageKey = 'vault_view_mode_v1';

  final FlutterSecureStorage _storage;

  /// Faz 3 Patch 1 — multi-vault namespace prefix'i (boş = Faz 2 byte-identical).
  final String _keyPrefix;

  ViewModeStore({FlutterSecureStorage? storage, String keyPrefix = ''})
    : _storage = storage ?? const FlutterSecureStorage(),
      _keyPrefix = keyPrefix;

  String get _key => '$_keyPrefix$storageKey';

  /// Kayıtlı tercih; yoksa varsayılan kart.
  Future<VaultViewMode> read() async {
    final raw = await _storage.read(key: _key);
    return raw == 'list' ? VaultViewMode.list : VaultViewMode.card;
  }

  Future<void> write(VaultViewMode mode) => _storage.write(
    key: _key,
    value: mode == VaultViewMode.list ? 'list' : 'card',
  );
}
