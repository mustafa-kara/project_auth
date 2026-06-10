/// Cihaz kaydı sunucu deposu — soyutlama (Faz 3 Patch 4).
///
/// `devices` tablosu (owner-only RLS; composite PK `(user_id, device_id)`). Sunucuya
/// yalnız **opak rastgele `device_id`** + opsiyonel `name`/`last_seen` gider — donanım
/// tanımlayıcı/IP/konum/telemetri ASLA. Sunucu şeması DEĞİŞMEZ. E2E yüzeyine DOKUNMAZ
/// (secret/masterKey taşımaz).
library;

import '../domain/sync_exceptions.dart';

/// Sunucudaki bir cihaz satırı (owner-only SELECT sonucu).
class DeviceRow {
  final String deviceId;
  final String? name;
  final DateTime? lastSeen;
  final DateTime createdAt;

  const DeviceRow({
    required this.deviceId,
    required this.name,
    required this.lastSeen,
    required this.createdAt,
  });
}

abstract interface class DeviceRepository {
  /// Cihazı kaydeder/günceller (idempotent upsert, `onConflict: 'user_id,device_id'`).
  /// `created_at` GÖNDERİLMEZ (DEFAULT now()). Ağ/izin hatası → [SyncError].
  Future<void> register(String uid, {required String deviceId, String? name});

  /// `last_seen`'i şimdiye günceller. **DÖNER: etkilenen satır sayısı** (0 = sunucuda
  /// row yok → registrar register-fallback yapar). Ağ/izin hatası → [SyncError].
  Future<int> touchLastSeen(String uid, String deviceId);

  /// Kullanıcının cihazlarını listeler (owner-only; RLS yalnız kendi satırları).
  /// Ağ/izin hatası → [SyncError]; malformed satır → [SyncMalformedRemote].
  Future<List<DeviceRow>> list(String uid);
}
