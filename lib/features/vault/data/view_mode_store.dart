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
  ViewModeStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Kayıtlı tercih; yoksa varsayılan kart.
  Future<VaultViewMode> read() async {
    final raw = await _storage.read(key: storageKey);
    return raw == 'list' ? VaultViewMode.list : VaultViewMode.card;
  }

  Future<void> write(VaultViewMode mode) =>
      _storage.write(key: storageKey, value: mode == VaultViewMode.list ? 'list' : 'card');
}
