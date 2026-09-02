/// Faz 1 plaintext vault → Faz 2 şifreli vault tek-seferlik geçişi.
///
/// Idempotency **ayrı commit marker** ile sağlanır (`vault_migration_v1`):
/// "encrypted var diye no-op" tuzağına düşmez. Crash-güvenli:
///   1. marker == committed → no-op (kesin bitti).
///   2. plaintext yok → marker'ı committed yaz, no-op (taşınacak veri yok).
///   3. plaintext var → şifreli repo'ya yaz → geri oku + DOĞRULA (tüm id'ler
///      mevcut, decrypt OK) → doğrulanırsa plaintext sil → marker committed.
///   4. Adım 3 ortasında crash → marker committed DEĞİL + plaintext duruyor →
///      sonraki açılışta adım 3 tekrar (id-bazlı upsert → duplicate yok).
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/crypto/crypto_service.dart';
import '../../../core/crypto/key_handle.dart';
import '../../../core/otp/otp_account.dart';
import 'encrypted_vault_repository.dart';

class VaultMigration {
  /// Faz 1 plaintext deposu (SecureStorageVaultRepository ile aynı anahtar).
  /// GLOBAL (uid-siz) — Faz 1 multi-vault'tan önceydi.
  static const _plaintextKey = 'vault_accounts_v1';

  /// Geçişin tamamlandığını işaretleyen ayrı marker (taban).
  static const markerKey = 'vault_migration_v1';
  static const _committed = 'committed';

  final CryptoService _crypto;
  final FlutterSecureStorage _storage;

  /// Faz 3 Patch 1 — hedef şifreli vault + marker namespace prefix'i (boş = Faz 2
  /// byte-identical). Plaintext kaynak GLOBAL kalır (taşınınca silinir).
  final String _keyPrefix;

  VaultMigration({
    required CryptoService crypto,
    FlutterSecureStorage? storage,
    String keyPrefix = '',
  }) : _crypto = crypto,
       _storage = storage ?? const FlutterSecureStorage(),
       _keyPrefix = keyPrefix;

  String get _markerKey => '$_keyPrefix$markerKey';

  /// Gerekirse Faz 1 plaintext token'ları [masterKey] ile şifreli vault'a taşır.
  /// `VaultCubit.load()`'tan ÖNCE çağrılmalı (yoksa eski plaintext dururken
  /// şifreli repo boş yüklenir + ileride çakışma).
  Future<void> migrateIfNeeded({required KeyHandle masterKey}) async {
    if (await _storage.read(key: _markerKey) == _committed) return; // (1)

    final plaintextRaw = await _storage.read(key: _plaintextKey);
    if (plaintextRaw == null || plaintextRaw.isEmpty) {
      // (2) Taşınacak veri yok → committed işaretle (bir daha bakma).
      await _storage.write(key: _markerKey, value: _committed);
      return;
    }

    // (3) Plaintext'i oku. Bozuk kayıtlar atlanır (sağlamlar taşınır).
    final accounts = _readPlaintext(plaintextRaw);

    final encrypted = EncryptedVaultRepository(
      masterKey: masterKey,
      crypto: _crypto,
      storage: _storage,
      keyPrefix: _keyPrefix,
    );

    // GERÇEK upsert (review P2): save() replace semantiğinde olduğu için önce
    // mevcut şifreli vault'u OKU → _lastById/_corruptedRaw dolar. Crash sonrası
    // yarım migration'da encrypted'te zaten kayıt olabilir; bunları kaybetmemek
    // için plaintext ile id-bazlı birleştir (mevcut şifreli kayıt KAZANIR, eksik
    // plaintext id'leri eklenir). Böylece duplicate yok + var olan ezilmez.
    final List<OtpAccount> existing;
    try {
      existing = (await encrypted.load()).accounts;
    } on Object {
      // Şifreli vault bütünlük hatası (bozulma/yanlış key) → DESTRUCTIVE adım
      // atma: plaintext'i silme, marker yazma. (Sonraki açılış tekrar dener;
      // gerçek bozulmaysa kullanıcı integrity ekranıyla karşılaşır.)
      return;
    }
    final existingIds = {for (final a in existing) a.id};
    final merged = [
      ...existing,
      ...accounts.where((a) => !existingIds.contains(a.id)),
    ];

    await encrypted.save(merged);

    // Doğrula: geri oku, tüm plaintext id'leri mevcut + decrypt OK.
    final result = await encrypted.load();
    final migratedIds = {for (final a in result.accounts) a.id};
    final expectedIds = {for (final a in accounts) a.id};
    final verified = expectedIds.difference(migratedIds).isEmpty;
    if (!verified) {
      // Doğrulanamadı → plaintext'i SİLME, marker yazma → sonraki açılış tekrar dener.
      return;
    }

    // Doğrulandı → plaintext sil → marker committed (sıra önemli: önce kaynak
    // silinir, sonra marker; ters olursa crash'te plaintext kalır ama
    // marker committed olur → veri kaybı YOK çünkü şifreli kopya doğrulandı).
    await _storage.delete(key: _plaintextKey);
    await _storage.write(key: _markerKey, value: _committed);
  }

  /// Plaintext JSON'u OtpAccount listesine çevirir (bozuk kayıt atlanır).
  List<OtpAccount> _readPlaintext(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (decoded is! List) return const [];
    final accounts = <OtpAccount>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      try {
        accounts.add(
          OtpAccount.fromJson({
            for (final e in item.entries) e.key.toString(): e.value,
          }),
        );
      } catch (_) {
        continue;
      }
    }
    return accounts;
  }
}
