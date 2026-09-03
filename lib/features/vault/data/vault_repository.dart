/// Vault token kalıcılığı — cihazda yerel saklama.
///
/// Faz 1: `flutter_secure_storage` ile **şifrelenmemiş** (henüz masterKey yok)
/// ama OS koruması altında (iOS Keychain / Android Keystore-destekli depo).
/// Token listesi tek bir JSON dizisi olarak tek anahtara yazılır.
///
/// Faz 2: bu JSON `masterKey` ile XChaCha20-Poly1305 ile şifrelenip öyle saklanacak
/// (interface aynı kalır; sadece serialize/deserialize katmanına AEAD eklenir).
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/otp/otp_account.dart';
import 'vault_load_result.dart';

/// Token'ların yüklenmesi/kaydedilmesi sözleşmesi. Test edilebilirlik için
/// soyut — bellek-içi sahte (fake) ile birim test edilebilir, prod'da
/// secure_storage implementasyonu kullanılır.
abstract interface class VaultRepository {
  /// Saklanan tüm token'ları yükler. Depo boşsa boş sonuç döner.
  /// Bozuk/okunamayan kayıt varsa atlanır (tüm vault'u kaybetmemek için) ve
  /// [VaultLoadResult.corruptedCount]'a sayılır.
  Future<VaultLoadResult> load();

  /// Verilen token listesini bütünüyle (atomik) saklar; önceki içeriği değiştirir.
  Future<void> save(List<OtpAccount> accounts);

  /// Çözülemeyen/bozuk kayıtları KALICI siler (sağlam + değişmemiş blob'lara
  /// dokunmaz). Yalnız açık kullanıcı onayıyla çağrılmalı (geri alınamaz).
  Future<void> purgeCorrupted();
}

/// Bellekte ÇÖZÜLMÜŞ plaintext tutan depoların "unut" portu (güvenlik denetimi
/// P2-1).
///
/// `VaultRepository`'ye EKLENMEZ, ayrı tutulur: her depo cache tutmaz (Faz 1
/// [SecureStorageVaultRepository] tutmuyor) ve arayüze zorunlu üye eklemek tüm
/// test sahtelerini kırardı. `VaultCubit.wipe()` runtime'da bu tipi kontrol eder.
///
/// **Sözleşme:** senkron olmalı ve ASLA fırlatmamalı — çağıran `masterKey`
/// dispose edilmeden hemen ÖNCE, bir frame'e bel bağlamadan çalıştırır.
abstract interface class PlaintextCache {
  /// Bellekte tutulan çözülmüş kayıtları bırakır. Diske DOKUNMAZ.
  void forgetPlaintext();
}

/// `flutter_secure_storage` tabanlı kalıcılık.
class SecureStorageVaultRepository implements VaultRepository {
  /// Tüm vault'un tutulduğu tek depo anahtarı.
  static const _vaultKey = 'vault_accounts_v1';

  final FlutterSecureStorage _storage;

  SecureStorageVaultRepository({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<VaultLoadResult> load() async {
    final raw = await _storage.read(key: _vaultKey);
    if (raw == null || raw.isEmpty) return VaultLoadResult.empty;

    // Üst düzey JSON bozuksa (kısmi yazma, manuel kurcalama) tüm yükleme
    // patlamasın — boş vault'a düş (kullanıcı en kötü ihtimalle yeniden ekler,
    // ama uygulama açılışta crash etmez). NOT: bu "boş düş" davranışı YALNIZ
    // plaintext Faz 1 repo'da geçerli; şifreli repo top-level bozulmada
    // VaultIntegrityException atar (sessiz veri kaybı maskelenmesin).
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return VaultLoadResult.empty;
    }
    if (decoded is! List) return VaultLoadResult.empty;

    final accounts = <OtpAccount>[];
    var corrupted = 0;
    for (final item in decoded) {
      if (item is! Map) {
        corrupted++;
        continue;
      }
      try {
        accounts.add(OtpAccount.fromJson(_coerceStringKeys(item)));
      } catch (_) {
        // Tek bozuk kayıt (geçersiz secret/digits/period veya YANLIŞ TİP) tüm
        // vault'u düşürmesin — atla + say. FormatException dışı (TypeError vb.)
        // de yakalanır: bozuk depodan gelen veri akışı kesmemeli.
        corrupted++;
      }
    }
    return VaultLoadResult(accounts: accounts, corruptedCount: corrupted);
  }

  @override
  Future<void> save(List<OtpAccount> accounts) async {
    final raw = jsonEncode([for (final a in accounts) a.toJson()]);
    await _storage.write(key: _vaultKey, value: raw);
  }

  /// Plaintext repo'da bozuk kayıtlar `load()`'ta zaten atlanıyor ve raw
  /// korunmuyor → sağlam kayıtları yeniden yazmak bozuk olanları düşürür.
  @override
  Future<void> purgeCorrupted() async {
    final result = await load();
    if (result.corruptedCount == 0) return; // no-op (sağlamlara dokunma)
    await save(result.accounts);
  }

  /// JSON map'in anahtarlarını String'e çevirir (jsonDecode zaten String anahtar
  /// üretir; bu, doğrudan kurcalanmış veriye karşı ek savunma).
  static Map<String, dynamic> _coerceStringKeys(Map<dynamic, dynamic> m) => {
    for (final e in m.entries) e.key.toString(): e.value,
  };
}
