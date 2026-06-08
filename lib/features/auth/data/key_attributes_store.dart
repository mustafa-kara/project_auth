/// `KeyAttributes` kalıcılık katmanı — `vault_key_attributes_v1` (Faz 2 Patch 4).
///
/// Guard state'inin kaynağı: açılışta [read] → null ise `uninitialized`, dolu ise
/// `locked`. **Yalnızca `KeyAttributes.toJson` (şifreli bloblar + KDF parametreleri)
/// yazılır** — ham master parola / recovery mnemonic ASLA buraya (veya hiçbir yere)
/// düz yazılmaz.
///
/// Malformed/parse hatası kararı (review P2 #2): `read()` parse `FormatException`
/// atarsa sessizce null (= `uninitialized`) DÖNDÜRMEZ → çağıran (`VaultLockCubit`)
/// bunu `keyAttributesCorrupted` state'ine çevirir. Yoksa var olan vault "ilk
/// kurulum" sanılıp üzerine yazılabilirdi.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/crypto/key_attributes.dart';

class KeyAttributesStore {
  /// Anahtar metadata'sının tutulduğu depo anahtarı (taban).
  static const storageKey = 'vault_key_attributes_v1';

  final FlutterSecureStorage _storage;

  /// Faz 3 Patch 1 — multi-vault namespace prefix'i (`'<uid>/'`). Boş ise Faz 2
  /// davranışıyla byte-identical (eski uid-siz anahtar).
  final String _keyPrefix;

  KeyAttributesStore({FlutterSecureStorage? storage, String keyPrefix = ''})
      : _storage = storage ?? const FlutterSecureStorage(),
        _keyPrefix = keyPrefix;

  String get _key => '$_keyPrefix$storageKey';

  /// Saklı attrs'ı okur. Yoksa null. **Bozuk/parse edilemez içerik → rethrow
  /// `FormatException`** (sessiz null DEĞİL — bkz. dosya başı). `jsonDecode`'un
  /// `!is Map` durumu da `FormatException`'a normalize edilir.
  Future<KeyAttributes?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const FormatException(
          'KeyAttributesStore: kayıtlı JSON bozuk (malformed)');
    }
    if (decoded is! Map) {
      throw const FormatException(
          'KeyAttributesStore: kayıt beklenen nesne formatında değil');
    }
    // KeyAttributes.fromJson eksik/yanlış tip/geçersiz base64'te FormatException atar.
    return KeyAttributes.fromJson(
        {for (final e in decoded.entries) e.key.toString(): e.value});
  }

  Future<void> write(KeyAttributes attrs) =>
      _storage.write(key: _key, value: jsonEncode(attrs.toJson()));

  Future<void> clear() => _storage.delete(key: _key);
}
