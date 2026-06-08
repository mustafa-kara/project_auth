/// Bekleyen e-posta onayı kalıcılığı (Faz 3 Patch 1, reviewer [P2]).
///
/// Supabase confirm-pending durumu kalıcı oturum DEĞİL → uygulama yeniden açılınca
/// kaybolurdu. Yanlış e-postayla kayıt olan kullanıcının sıkışmaması ve onay
/// ekranına geri dönebilmesi için bekleyen e-posta küçük bir secure store'da tutulur.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class PendingConfirmationStore {
  static const storageKey = 'auth_pending_email_v1';

  final FlutterSecureStorage _storage;

  PendingConfirmationStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  Future<String?> read() => _storage.read(key: storageKey);

  Future<void> write(String email) =>
      _storage.write(key: storageKey, value: email);

  Future<void> clear() => _storage.delete(key: storageKey);
}
