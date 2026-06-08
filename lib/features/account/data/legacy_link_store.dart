/// Per-uid legacy (Faz 2 uid-siz) vault bağlama kararı marker'ı (Faz 3 Patch 1,
/// reviewer [P3]).
///
/// Her Supabase uid, cihazdaki uid-siz Faz2 vault hakkında BAĞIMSIZ karar verir
/// ("bu hesaba ilişkilendir" veya "yeni boş vault"). Karar verilince marker yazılır
/// → o uid için `linkRequired` düşer. Global DEĞİL: A "yeni vault" dese B'ye legacy
/// yine teklif edilir (B'nin marker'ı yok).
///
/// Anahtar şeması: `legacy_link_decided/<uid>`.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class LegacyLinkStore {
  static const _prefix = 'legacy_link_decided/';

  final FlutterSecureStorage _storage;

  LegacyLinkStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  String _key(String uid) => '$_prefix$uid';

  /// Bu uid legacy vault hakkında karar verdi mi?
  Future<bool> isDecided(String uid) async =>
      (await _storage.read(key: _key(uid))) == 'true';

  /// Kararı işaretle (ilişkilendir VEYA yeni-vault — her ikisi de çağırır).
  Future<void> markDecided(String uid) =>
      _storage.write(key: _key(uid), value: 'true');

  Future<void> clear(String uid) => _storage.delete(key: _key(uid));
}
