/// E2E şifreli vault deposu — token-bazlı kayıtlar (Faz 2 Patch 3).
///
/// Her token ayrı bir şifreli kayıt: `{id, version, nonce, ciphertext, updatedAt,
/// deleted}`. Plaintext (`OtpAccount.toJson`) masterKey + XChaCha20-Poly1305 ile
/// şifrelenir; AAD = `token|1|<id>` kaydı kimliğine bağlar (bir blob başka id'de
/// veya bağlamda çözülemez). Bu şema Faz 3 `tokens` tablosuna birebir taşınır.
///
/// Tasarım kararları (review):
/// - **Unchanged-blob koruması:** `save()` her seferinde TÜM token'ları yeniden
///   şifrelemez; yalnız içeriği değişen/yeni kayıtlar yeniden şifrelenir +
///   `updatedAt` yenilenir. Değişmeyenler eski blob'u korur (counter artışında
///   tüm vault re-encrypt edilmez; Faz 3 sync'inde gereksiz diff önlenir).
/// - **Bozuk kayıt koruması:** `load()` çözülemeyen raw kayıtları bellekte tutar;
///   `save()` onları AYNEN geri yazar (kullanıcı banner'a rağmen token eklerse
///   çözülemeyen kayıt SİLİNMEZ). Yalnız `purgeCorrupted()` açık onayla siler.
/// - **Sessiz veri kaybı yok:** top-level bozulma (malformed/non-list) VEYA tüm
///   kayıtların decrypt fail'i → `VaultIntegrityException` ("boş vault" gösterilmez).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/crypto/crypto_exceptions.dart';
import '../../../core/crypto/crypto_service.dart';
import '../../../core/crypto/encrypted_blob.dart';
import '../../../core/crypto/key_handle.dart';
import '../../../core/otp/otp_account.dart';
import 'vault_load_result.dart';
import 'vault_repository.dart';

/// Tek bir şifreli token kaydı (storage temsili). `deleted` Faz 2'de hep false
/// (soft-delete Faz 3 API genişlemesi gerektirir — bkz. plan).
class _TokenRecord {
  final String id;
  final int version;
  final EncryptedBlob blob;
  final int updatedAt; // epoch ms (client-side; Faz 3 server trigger ezer)
  final bool deleted;

  _TokenRecord({
    required this.id,
    required this.blob,
    required this.updatedAt,
    this.version = 1,
    this.deleted = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'v': version,
        'n': base64Encode(blob.nonce),
        'c': base64Encode(blob.ciphertext),
        'updatedAt': updatedAt,
        'deleted': deleted,
      };
}

class EncryptedVaultRepository implements VaultRepository {
  /// Token-bazlı şifreli kayıt dizisinin tutulduğu depo anahtarı.
  static const _vaultKey = 'vault_encrypted_v1';

  /// AAD prefix'i — record tipi + şema versiyonu. Tam AAD: `token|1|<id>`.
  static const _aadPrefix = 'token|1|';

  final KeyHandle _masterKey;
  final CryptoService _crypto;
  final FlutterSecureStorage _storage;

  /// Bir önceki `load()`'tan kalan durum (unchanged-blob + bozuk-kayıt koruması):
  ///   - `_lastById`: id → (plaintext'i bilinen) sağlam kayıt + blob'u + meta.
  ///   - `_corruptedRaw`: decode/decrypt edilemeyen ham JSON kayıtları (aynen taşınır).
  final Map<String, _LoadedRecord> _lastById = {};
  final List<Object?> _corruptedRaw = [];

  EncryptedVaultRepository({
    required KeyHandle masterKey,
    required CryptoService crypto,
    FlutterSecureStorage? storage,
  })  : _masterKey = masterKey,
        _crypto = crypto,
        _storage = storage ?? const FlutterSecureStorage();

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  Uint8List _aad(String id) => Uint8List.fromList('$_aadPrefix$id'.codeUnits);

  @override
  Future<VaultLoadResult> load() async {
    _lastById.clear();
    _corruptedRaw.clear();

    final raw = await _storage.read(key: _vaultKey);
    if (raw == null || raw.isEmpty) return VaultLoadResult.empty;

    // Top-level bozulma şifreli vault'ta CİDDİDİR → boş listeye düşmek token
    // kaybını gizler. Bunun yerine VaultIntegrityException (review).
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const VaultIntegrityException(
          'Şifreli vault JSON\'u bozuk (malformed)');
    }
    if (decoded is! List) {
      throw const VaultIntegrityException(
          'Şifreli vault beklenen dizi formatında değil');
    }

    final accounts = <OtpAccount>[];
    var corrupted = 0;
    for (final item in decoded) {
      final parsed = _tryParseRecord(item);
      if (parsed == null) {
        // record şeması bozuk → raw'ı koru, say
        _corruptedRaw.add(item);
        corrupted++;
        continue;
      }
      final (id, version, blob, updatedAt, deleted) = parsed;
      try {
        final plaintext =
            _crypto.decrypt(blob: blob, key: _masterKey, aad: _aad(id));
        final account = OtpAccount.fromJson(
            _coerceStringKeys(jsonDecode(utf8.decode(plaintext)) as Map));
        accounts.add(account);
        _lastById[id] = _LoadedRecord(
          account: account,
          blob: blob,
          version: version,
          updatedAt: updatedAt,
          deleted: deleted,
        );
      } catch (_) {
        // decrypt fail (tamper/yanlış key) VEYA çözülen plaintext bozuk →
        // raw'ı koru (silme!), say.
        _corruptedRaw.add(item);
        corrupted++;
      }
    }

    // Tüm kayıtlar fail (yanlış masterKey / toptan bozulma) → integrity error,
    // boş vault gösterme (review).
    if (accounts.isEmpty && corrupted > 0) {
      throw VaultIntegrityException(
          'Hiçbir kayıt çözülemedi ($corrupted kayıt) — yanlış anahtar/bozulma');
    }

    return VaultLoadResult(accounts: accounts, corruptedCount: corrupted);
  }

  @override
  Future<void> save(List<OtpAccount> accounts) async {
    // Object? — sağlam kayıtlar Map; korunan bozuk raw kayıtlar herhangi bir
    // JSON değeri olabilir (map/scalar/null). Hepsi AYNEN geri yazılır.
    final records = <Object?>[];

    for (final account in accounts) {
      final prev = _lastById[account.id];
      if (prev != null && prev.account == account) {
        // Değişmemiş → eski blob'u koru (yeniden şifreleme + updatedAt yenileme YOK).
        records.add(_TokenRecord(
          id: account.id,
          blob: prev.blob,
          version: prev.version,
          updatedAt: prev.updatedAt,
          deleted: prev.deleted,
        ).toJson());
      } else {
        // Yeni veya değişmiş → şifrele + updatedAt yenile.
        final plaintext =
            Uint8List.fromList(utf8.encode(jsonEncode(account.toJson())));
        final blob =
            _crypto.encrypt(plaintext: plaintext, key: _masterKey, aad: _aad(account.id));
        final updatedAt = _nowMs();
        records.add(_TokenRecord(
          id: account.id,
          blob: blob,
          updatedAt: updatedAt,
        ).toJson());
        _lastById[account.id] = _LoadedRecord(
          account: account,
          blob: blob,
          version: 1,
          updatedAt: updatedAt,
          deleted: false,
        );
      }
    }

    // Çözülemeyen eski raw kayıtlar AYNEN korunur (kullanıcı banner'a rağmen
    // token eklese bile bozuk kayıt düşmesin — review). Bozuk kayıt map değil
    // (string/sayı/null) de olabilir → tip cast YOK, verbatim geri yazılır.
    records.addAll(_corruptedRaw);

    // Bu save'de artık var olmayan id'leri _lastById'den temizle (kullanıcı sildi).
    final presentIds = {for (final a in accounts) a.id};
    _lastById.removeWhere((id, _) => !presentIds.contains(id));

    await _storage.write(key: _vaultKey, value: jsonEncode(records));
  }

  @override
  Future<void> purgeCorrupted() async {
    if (_corruptedRaw.isEmpty) return; // no-op (sağlamlara dokunma)
    _corruptedRaw.clear();
    // Yalnız sağlam (bilinen) kayıtları yeniden yaz — unchanged blob'lar korunur.
    final survivors =
        _lastById.values.map((r) => r.account).toList(growable: false);
    await save(survivors);
  }

  /// Tek record JSON'ını ayrıştırır. Şema bozuksa null (çağıran bozuk sayar).
  (String, int, EncryptedBlob, int, bool)? _tryParseRecord(Object? item) {
    if (item is! Map) return null;
    final map = _coerceStringKeys(item);
    final id = map['id'];
    final n = map['n'];
    final c = map['c'];
    if (id is! String || n is! String || c is! String) return null;
    final EncryptedBlob blob;
    try {
      blob = EncryptedBlob.fromJson({'v': map['v'], 'n': n, 'c': c});
    } on FormatException {
      return null;
    }
    final version = map['v'] is num ? (map['v'] as num).toInt() : 1;
    final updatedAt = map['updatedAt'] is num ? (map['updatedAt'] as num).toInt() : 0;
    final deleted = map['deleted'] == true;
    return (id, version, blob, updatedAt, deleted);
  }

  static Map<String, dynamic> _coerceStringKeys(Map<dynamic, dynamic> m) =>
      {for (final e in m.entries) e.key.toString(): e.value};
}

/// `load()` sonrası bellekte tutulan sağlam kayıt (unchanged-blob karşılaştırması
/// + purge survivor'ı için).
class _LoadedRecord {
  final OtpAccount account;
  final EncryptedBlob blob;
  final int version;
  final int updatedAt;
  final bool deleted;

  _LoadedRecord({
    required this.account,
    required this.blob,
    required this.version,
    required this.updatedAt,
    required this.deleted,
  });
}
