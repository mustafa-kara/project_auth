/// E2E şifreli vault deposu — token-bazlı kayıtlar (Faz 2 Patch 3).
///
/// Her token ayrı bir şifreli kayıt: `{id, version, nonce, ciphertext, updatedAt,
/// deleted, sv}`. Plaintext (`OtpAccount.toJson`) masterKey + XChaCha20-Poly1305 ile
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
///
/// **Faz 3 Patch 3 — `RawTokenStore` (token sync):** çözülmüş `VaultRepository`
/// arayüzü DEĞİŞMEZ; sync için AYRI ham port eklenir (`exportRaw`/`importRemote`/
/// `markDeleted`). Bunlar masterKey GEREKTİRMEZ (opak ciphertext'i açmadan okur/yazar);
/// tombstone (soft-delete) ve `sv` (sunucu cursor'u) bu sınıfta tutulur.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/crypto/crypto_exceptions.dart';
import '../../../core/crypto/crypto_service.dart';
import '../../../core/crypto/encrypted_blob.dart';
import '../../../core/crypto/key_handle.dart';
import '../../../core/otp/otp_account.dart';
import '../domain/raw_token_record.dart';
import '../domain/remote_token_repository.dart';
import 'vault_load_result.dart';
import 'vault_repository.dart';

/// Tek bir şifreli token kaydı (storage temsili). `deleted=true` → tombstone
/// (soft-delete; `load()` hesaplarda göstermez ama `exportRaw` döndürür). `sv` =
/// bu kaydın en son uzlaşıldığı SUNUCU `updated_at`'i (null = lokal-dirty / hiç sync edilmemiş).
class _TokenRecord {
  final String id;
  final int version;
  final EncryptedBlob blob;
  final int updatedAt; // epoch ms (client-side; sunucu trigger'ı ayrı tutulur — sv)
  final bool deleted;
  final String? serverUpdatedAtIso; // 'sv' — sunucu cursor'u (LWW); null = dirty

  _TokenRecord({
    required this.id,
    required this.blob,
    required this.updatedAt,
    this.version = 1,
    this.deleted = false,
    this.serverUpdatedAtIso,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'v': version,
        'n': base64Encode(blob.nonce),
        'c': base64Encode(blob.ciphertext),
        'updatedAt': updatedAt,
        'deleted': deleted,
        if (serverUpdatedAtIso != null) 'sv': serverUpdatedAtIso,
      };

  RawTokenRecord toRaw() => RawTokenRecord(
        id: id,
        blob: blob,
        updatedAtMs: updatedAt,
        version: version,
        deleted: deleted,
        serverUpdatedAtIso: serverUpdatedAtIso,
      );
}

class EncryptedVaultRepository implements VaultRepository, RawTokenStore {
  /// Token-bazlı şifreli kayıt dizisinin tutulduğu depo anahtarı (taban).
  static const vaultKey = 'vault_encrypted_v1';

  /// AAD prefix'i — record tipi + şema versiyonu. Tam AAD: `token|1|<id>`.
  static const _aadPrefix = 'token|1|';

  final KeyHandle _masterKey;
  final CryptoService _crypto;
  final FlutterSecureStorage _storage;

  /// Faz 3 Patch 1 — multi-vault namespace prefix'i (boş = Faz 2 byte-identical).
  /// **AAD DEĞİŞMEZ** (`token|1|<id>`) — namespace yalnız storage ANAHTARINI etkiler,
  /// ciphertext bağlamını değil (id zaten globalce benzersiz UUID).
  final String _vaultStorageKey;

  /// Bir önceki `load()`'tan kalan durum (unchanged-blob + bozuk-kayıt koruması):
  ///   - `_lastById`: id → (plaintext'i bilinen) sağlam CANLI kayıt + blob'u + meta.
  ///   - `_tombstones`: id → soft-delete tombstone (deleted=true; `load` accounts'a koymaz).
  ///   - `_corruptedRaw`: decode/decrypt edilemeyen ham JSON kayıtları (aynen taşınır).
  final Map<String, _LoadedRecord> _lastById = {};
  final Map<String, _TokenRecord> _tombstones = {};
  final List<Object?> _corruptedRaw = [];

  EncryptedVaultRepository({
    required KeyHandle masterKey,
    required CryptoService crypto,
    FlutterSecureStorage? storage,
    String keyPrefix = '',
  })  : _masterKey = masterKey,
        _crypto = crypto,
        _storage = storage ?? const FlutterSecureStorage(),
        _vaultStorageKey = '$keyPrefix$vaultKey';

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  Uint8List _aad(String id) => Uint8List.fromList('$_aadPrefix$id'.codeUnits);

  @override
  Future<VaultLoadResult> load() async {
    _lastById.clear();
    _tombstones.clear();
    _corruptedRaw.clear();

    final raw = await _storage.read(key: _vaultStorageKey);
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
      // Tombstone (soft-delete): hesaplarda gösterme ama push için sakla.
      if (parsed.deleted) {
        _tombstones[parsed.id] = parsed;
        continue;
      }
      final id = parsed.id;
      // A1 defence-in-depth: a well-formed store never holds two live records
      // for one id, but a hand-edited/half-merged file could. Keep the FIRST
      // one instead of emitting the account twice — a duplicated id would show
      // up twice in the UI, be deleted twice by `removeById`, and make
      // `pushUpsert`'s `onConflict: 'id'` fail with Postgres 21000, which
      // wedges every later push.
      if (_lastById.containsKey(id)) continue;
      try {
        final plaintext =
            _crypto.decrypt(blob: parsed.blob, key: _masterKey, aad: _aad(id));
        final account = OtpAccount.fromJson(
            _coerceStringKeys(jsonDecode(utf8.decode(plaintext)) as Map));
        accounts.add(account);
        _lastById[id] = _LoadedRecord(
          account: account,
          blob: parsed.blob,
          version: parsed.version,
          updatedAt: parsed.updatedAt,
          serverUpdatedAtIso: parsed.serverUpdatedAtIso,
        );
      } catch (_) {
        // decrypt fail (tamper/yanlış key) VEYA çözülen plaintext bozuk →
        // raw'ı koru (silme!), say.
        _corruptedRaw.add(item);
        corrupted++;
      }
    }

    // A1: a live record WINS over its own tombstone (deliberate resurrection).
    // The pair can only exist after an id-preserving backup restore of a token
    // the user had deleted; the user just asked for that token back. Dropping
    // the tombstone here (instead of hiding the account) means the freshly
    // written record is dirty (`sv == null`) and the next push flips the server
    // row back to `deleted = false`. Keeping both would silently lose the token
    // on the next `importRemote` and break push with a duplicate-id upsert.
    _tombstones.removeWhere((id, _) => _lastById.containsKey(id));

    // Tüm kayıtlar fail (yanlış masterKey / toptan bozulma) → integrity error,
    // boş vault gösterme (review). NOT: tombstone-only vault (canlı 0 + corrupted 0)
    // GEÇERLİDİR (kullanıcı hepsini sildi) → integrity hatası DEĞİL.
    if (accounts.isEmpty && corrupted > 0) {
      throw VaultIntegrityException(
          'Hiçbir kayıt çözülemedi ($corrupted kayıt) — yanlış anahtar/bozulma');
    }

    return VaultLoadResult(accounts: accounts, corruptedCount: corrupted);
  }

  @override
  Future<void> save(List<OtpAccount> accounts) async {
    await _writeRecords(accounts);
  }

  /// Canlı hesapları (+ tombstone + corrupted) tek atomik JSON-array olarak yazar.
  /// `save` ve `markDeleted` bunu paylaşır.
  Future<void> _writeRecords(List<OtpAccount> accounts) async {
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
          serverUpdatedAtIso: prev.serverUpdatedAtIso,
        ).toJson());
      } else {
        // Yeni veya değişmiş → şifrele + updatedAt yenile + sv temizle (dirty).
        final plaintext =
            Uint8List.fromList(utf8.encode(jsonEncode(account.toJson())));
        final blob = _crypto.encrypt(
            plaintext: plaintext, key: _masterKey, aad: _aad(account.id));
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
          serverUpdatedAtIso: null, // lokal değişiklik → dirty (push edilecek)
        );
      }
    }

    // Bu save'de var olan id'ler — tombstone filtresi ve `_lastById` temizliği
    // ikisi de bunu kullanır (A1: filtre tombstone döngüsünden ÖNCE hesaplanmalı).
    final presentIds = {for (final a in accounts) a.id};

    // A1: a live account overrides its own tombstone. Without this both records
    // reach the disk, `importRemote` later lets the tombstone win (silent loss)
    // and `pushUpsert(onConflict: 'id')` dies with Postgres 21000 while both are
    // dirty. Dropping it is a DELIBERATE resurrection: the live record is dirty
    // (`sv == null`), so the next push sets `deleted = false` on the server.
    _tombstones.removeWhere((id, _) => presentIds.contains(id));

    // Tombstone'lar (soft-delete) AYNEN korunur → push edilebilsin + bir sonraki
    // save token'ı diriltmesin (sunucu hâlâ row'a sahip; tombstone gitmezse LWW geri ekler).
    for (final t in _tombstones.values) {
      records.add(t.toJson());
    }

    // Çözülemeyen eski raw kayıtlar AYNEN korunur (kullanıcı banner'a rağmen
    // token eklese bile bozuk kayıt düşmesin — review). Bozuk kayıt map değil
    // (string/sayı/null) de olabilir → tip cast YOK, verbatim geri yazılır.
    records.addAll(_corruptedRaw);

    // Bu save'de artık var olmayan id'leri _lastById'den temizle (kullanıcı sildi).
    _lastById.removeWhere((id, _) => !presentIds.contains(id));

    await _storage.write(key: _vaultStorageKey, value: jsonEncode(records));
  }

  @override
  Future<void> purgeCorrupted() async {
    if (_corruptedRaw.isEmpty) return; // no-op (sağlamlara dokunma)
    _corruptedRaw.clear();
    // Yalnız sağlam (bilinen) kayıtları yeniden yaz — unchanged blob'lar + tombstone korunur.
    final survivors =
        _lastById.values.map((r) => r.account).toList(growable: false);
    await _writeRecords(survivors);
  }

  // --- RawTokenStore (Faz 3 Patch 3 — token sync; masterKey GEREKTİRMEZ) ---

  /// Diskteki ham kayıtlar (canlı + tombstone), **id başına en fazla bir tane**.
  ///
  /// **Id tekilliği (A2):** `_corruptedRaw` decrypt'i başarısız olan kayıtları da
  /// tutar; bunlar ŞEMA olarak geçerlidir (nonce/ciphertext parse edilir), yalnız
  /// plaintext'leri çözülemez. `load()` böyle bir kaydı `_corruptedRaw`'a, aynı
  /// id'nin ikinci (çözülebilen) kaydını `_lastById`'ye koyabilir; `_writeRecords`
  /// ikisini de diske yazar. Tekilleştirme olmadan `exportRaw` aynı id'yi iki kez
  /// döndürür ve `pushUpsert(onConflict: 'id')` Postgres 21000 ("ON CONFLICT DO
  /// UPDATE command cannot affect row a second time") ile ölür — bu da SONRAKİ TÜM
  /// push'ları kilitler. Kural `load`/`importRemote` ile aynı: CANLI kayıt kendi
  /// tombstone'unu yener (kasıtlı diriltme), aynı türden ikisinde İLKİ kazanır.
  @override
  Future<List<RawTokenRecord>> exportRaw() async {
    // DİSKTEN okur (decrypt YOK) → in-memory `_lastById`/`_tombstones` tazeliğine
    // BAĞLI DEĞİL (merge-sonrası-reload yarışına kapalı). Şeması bozuk kayıtlar
    // atlanır (push edilemez; zaten geçersiz). Canlı + tombstone döner.
    final raw = await _storage.read(key: _vaultStorageKey);
    if (raw == null || raw.isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (decoded is! List) return const [];
    // LinkedHashMap → disk sırası korunur (ilk-kazanır deterministik kalır).
    final byId = <String, _TokenRecord>{};
    for (final item in decoded) {
      final rec = _tryParseRecord(item);
      if (rec == null) continue;
      final seen = byId[rec.id];
      if (seen == null || (seen.deleted && !rec.deleted)) byId[rec.id] = rec;
    }
    return [for (final rec in byId.values) rec.toRaw()];
  }

  @override
  Future<void> markDeleted(String id) async {
    final prev = _lastById[id];
    if (prev == null) {
      // Zaten yok / zaten tombstone → idempotent no-op (tombstone'a dokunma).
      return;
    }
    // Son bilinen blob'u koru (sunucu zaten ona sahip; tombstone geçerli EncryptedBlob
    // taşımalı — 24B nonce/16B ct minimumu). deleted=true + taze updatedAt + sv=null (dirty).
    _tombstones[id] = _TokenRecord(
      id: id,
      blob: prev.blob,
      version: prev.version,
      updatedAt: _nowMs(),
      deleted: true,
    );
    _lastById.remove(id);
    // Canlı kalanları + güncel tombstone'ları ATOMİK yaz.
    final survivors =
        _lastById.values.map((r) => r.account).toList(growable: false);
    await _writeRecords(survivors);
  }

  /// Remote satırları LWW ile diske merge eder (decrypt YOK).
  ///
  /// **Null cursor kuralı (A2):** `pullCursorIso == null` = bu cihaz HİÇ başarılı
  /// pull yapmamış. O durumda bir server satırının lokal dirty kaydımızdan SONRA
  /// gelip gelmediğini kanıtlayacak referans noktası yoktur, bu yüzden **dirty
  /// lokal kayıt korunur** (server satırı — tombstone dahil — uygulanmaz).
  /// Lokali OLMAYAN id'ler her zaman kabul edilir, yani ilk pull yine tüm remote
  /// token'ları getirir; yalnız push bekleyen kayıtlar dokunulmaz kalır.
  ///
  /// Bunu gerektiren senaryo: id koruyan bir yedek geri yüklenir, silinmiş bir
  /// token diriltilir (canlı + `sv == null`), ve cihaz ilk sync'ini yapar. Eski
  /// kural (`pullCursorIso == null` → server kazanır) sunucudaki tombstone'un
  /// yeni diriltilen kaydı SESSİZCE silmesine yol açıyordu.
  ///
  /// **Davranış değişikliği:** ilk pull'da dirty bir lokal kayıt ile aynı id'li
  /// bir remote satır çarpışırsa artık LOKAL kazanır; çakışma push sonrası
  /// sunucudaki LWW ile çözülür (bir sonraki pull uzlaşılmış satırı geri getirir).
  @override
  Future<TokenMergeOutcome> importRemote(
    List<RemoteTokenRow> remote, {
    required String? pullCursorIso,
  }) async {
    // KENDİ KENDİNE YETER (decrypt YOK + `_lastById`'ye bağlı DEĞİL): diskteki ham
    // kayıtları DOĞRUDAN okur, merge eder, ham yazar. Import sonrası VaultCubit
    // `reloadFromStore()` çağırır → `_lastById` decrypt'le yeniden dolar (zorunlu).
    final raw = await _storage.read(key: _vaultStorageKey);
    final byId = <String, _TokenRecord>{}; // canlı + tombstone (id → kayıt)
    final corruptedRaw = <Object?>[]; // verbatim korunur (decode edilemeyenler)
    // Disk carried more than one record for the same id → rewrite even if no
    // remote row wins, so the duplicate does not survive to the next push.
    var healedDuplicate = false;

    if (raw != null && raw.isNotEmpty) {
      final Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        // Top-level bozulma → merge etme (token kaybını maskeleme); değişiklik yok.
        return TokenMergeOutcome.none;
      }
      if (decoded is! List) return TokenMergeOutcome.none;
      for (final item in decoded) {
        final rec = _tryParseRecord(item);
        if (rec == null) {
          corruptedRaw.add(item);
          continue;
        }
        final seen = byId[rec.id];
        if (seen == null) {
          byId[rec.id] = rec;
          continue;
        }
        // A1 defence-in-depth: the disk should never hold two records for one
        // id. If it does, the LIVE one wins (same deliberate resurrection rule
        // as `load`/`_writeRecords`) and the extra record is dropped, which
        // heals the file — `byId` alone would silently keep whichever came
        // last. Two live rows: first wins, matching `load`.
        if (seen.deleted && !rec.deleted) byId[rec.id] = rec;
        healedDuplicate = true;
      }
    }

    var changed = healedDuplicate;
    var applied = 0;

    for (final r in remote) {
      final local = byId[r.id];
      final accept = local == null
          ? true // remote-only → kabul
          : local.serverUpdatedAtIso == null
              // Lokal dirty (push beklemede): server YALNIZ pull-cursor'dan SONRAki
              // bir değişiklikse kazanır (başka cihaz); aksi halde kendi echo'muz → KORU.
              // `pullCursorIso == null` (bu cihaz HİÇ başarılı pull yapmadı) →
              // "cursor'dan sonra" KANITLANAMAZ → dirty lokal KORUNUR (bkz. doc).
              ? (pullCursorIso != null &&
                  _isoNewer(r.serverUpdatedAtIso, pullCursorIso))
              // sv'de uzlaşılmış: server daha yeniyse kazanır (idempotent).
              : _isoNewer(r.serverUpdatedAtIso, local.serverUpdatedAtIso!);

      if (!accept) continue;

      // Kazanan remote satırı uygula (deleted bir alandır; tombstone = deleted=true kayıt).
      byId[r.id] = _TokenRecord(
        id: r.id,
        blob: r.blob,
        version: r.version,
        updatedAt: _nowMs(), // lokal bookkeeping; merge kararı sv ile yapılır
        deleted: r.deleted,
        serverUpdatedAtIso: r.serverUpdatedAtIso,
      );
      changed = true;
      applied++;
    }

    if (!changed) return TokenMergeOutcome.none;

    // Ham yaz: tüm kayıtlar (canlı + tombstone) + corrupted verbatim. Decrypt YOK.
    final records = <Object?>[
      for (final rec in byId.values) rec.toJson(),
      ...corruptedRaw,
    ];
    await _storage.write(key: _vaultStorageKey, value: jsonEncode(records));
    return TokenMergeOutcome(changed: changed, appliedCount: applied);
  }

  /// ISO-8601 UTC string kıyası — DateTime parse ile (ham leksik kıyas YASAK).
  /// `a > b` (a, b'den kesin yeni) → true.
  static bool _isoNewer(String a, String b) {
    final da = DateTime.tryParse(a)?.toUtc();
    final db = DateTime.tryParse(b)?.toUtc();
    if (da == null || db == null) return false; // güvenli: kıyaslanamazsa kabul etme
    return da.isAfter(db);
  }

  /// Tek record JSON'ını ayrıştırır. Şema bozuksa null (çağıran bozuk sayar).
  _TokenRecord? _tryParseRecord(Object? item) {
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
    final sv = map['sv'] is String ? map['sv'] as String : null;
    return _TokenRecord(
      id: id,
      blob: blob,
      version: version,
      updatedAt: updatedAt,
      deleted: deleted,
      serverUpdatedAtIso: sv,
    );
  }

  static Map<String, dynamic> _coerceStringKeys(Map<dynamic, dynamic> m) =>
      {for (final e in m.entries) e.key.toString(): e.value};
}

/// `load()` sonrası bellekte tutulan sağlam CANLI kayıt (unchanged-blob karşılaştırması
/// + purge survivor'ı + raw export için).
class _LoadedRecord {
  final OtpAccount account;
  final EncryptedBlob blob;
  final int version;
  final int updatedAt;
  final String? serverUpdatedAtIso;

  _LoadedRecord({
    required this.account,
    required this.blob,
    required this.version,
    required this.updatedAt,
    required this.serverUpdatedAtIso,
  });
}
