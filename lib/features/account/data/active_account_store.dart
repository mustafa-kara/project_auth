/// Aktif lokal vault sahibi uid (Faz 3 Patch 1, kullanıcı kararı 7 — multi-vault).
///
/// TEK global değer: o an HANGİ Supabase uid'inin lokal vault namespace'i aktif.
/// **"Aktiflik" ≠ "legacy kararı"** (reviewer [P3]): legacy uid-siz Faz2 vault'unun
/// hangi uid'e bağlanacağı AYRI per-uid marker'da tutulur (`LegacyLinkStore`).
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ActiveAccountStore {
  static const storageKey = 'vault_active_uid_v1';

  final FlutterSecureStorage _storage;

  ActiveAccountStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  Future<String?> read() => _storage.read(key: storageKey);

  Future<void> write(String uid) =>
      _storage.write(key: storageKey, value: uid);

  Future<void> clear() => _storage.delete(key: storageKey);
}
