/// Kararlı cihaz kimliği deposu (Faz 3 Patch 4) — `stable_device_id_v1`.
///
/// **GLOBAL** (keyPrefix YOK) — uid'den BAĞIMSIZ: aynı fiziksel cihaz tüm Supabase
/// hesaplarında AYNI `device_id`'yi paylaşır (kullanıcı kararı). **Donanım türevi
/// DEĞİL** — rastgele `uuid v4` (gizlilik dostu; reinstall'da değişir, kabul edilebilir;
/// IP/donanım tanımlayıcı/konum ASLA toplanmaz).
///
/// **TRADEOFF (cross-account correlation — KABUL EDİLDİ):** aynı cihazda birden fazla
/// hesap kullanılırsa backend/service_role aynı `device_id` üzerinden hesapları
/// İLİŞKİLENDİREBİLİR. Bu, multi-device list tutarlılığı için basitlik adına kabul
/// edildi (bkz. docs/CRYPTO.md). Alternatif `HMAC(local_secret, uid)` ileri ince ayar.
///
/// **signOut'ta KORUNUR** (vault reset'inde silinmez) → aynı cihaz tekrar login'de aynı
/// id ile register → sunucuda duplicate YOK (composite PK `user_id,device_id`).
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class StableDeviceIdStore {
  static const storageKey = 'stable_device_id_v1';

  final FlutterSecureStorage _storage;
  final Uuid _uuid;

  StableDeviceIdStore({FlutterSecureStorage? storage, Uuid? uuid})
    : _storage = storage ?? const FlutterSecureStorage(),
      _uuid = uuid ?? const Uuid();

  /// Kayıtlı device_id; henüz üretilmemişse null.
  Future<String?> read() => _storage.read(key: storageKey);

  /// device_id'yi döner; yoksa rastgele `uuid v4` üretir + kalıcı yazar + döner.
  /// Idempotent: ikinci çağrı AYNI id'yi döner.
  Future<String> getOrCreate() async {
    final existing = await _storage.read(key: storageKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = _uuid.v4();
    await _storage.write(key: storageKey, value: id);
    return id;
  }
}
