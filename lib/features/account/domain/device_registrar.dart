/// Cihaz kaydı orchestrator'ı (Faz 3 Patch 4) — hafif, best-effort.
///
/// Kimlik (uid) + lifecycle (signedIn/resume) ile ilgili; vault/E2E ile DEĞİL → SessionCubit'i
/// şişirmemek için ayrı. masterKey TUTMAZ. Hata kullanıcıyı BLOKLAMAZ (sessiz yutulur,
/// sonraki tetikte yeniden denenir — idempotent upsert).
library;

import 'dart:async';

import '../data/stable_device_id_store.dart';
import 'device_repository.dart';

class DeviceRegistrar {
  DeviceRegistrar({
    required DeviceRepository repo,
    required StableDeviceIdStore idStore,
  }) : _repo = repo,
       _idStore = idStore;

  final DeviceRepository _repo;
  final StableDeviceIdStore _idStore;

  /// Tek in-flight guard (kısa pencerede çift register/touch'ı engeller).
  bool _inFlight = false;

  /// signedIn'de çağrılır: device_id üret (yoksa) + register (idempotent upsert).
  Future<void> onSignedIn(String uid) async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      final id = await _idStore.getOrCreate();
      await _repo.register(uid, deviceId: id);
    } catch (_) {
      // best-effort: sonraki resume/signedIn yeniden dener.
    } finally {
      _inFlight = false;
    }
  }

  /// resume'da çağrılır: `last_seen` heartbeat. **0 satır etkilendiyse register-fallback**
  /// (ilk register ağ hatasıyla düşmüşse local id VAR ama sunucuda ROW YOK → UPDATE 0 satır
  /// → idempotent register row'u OLUŞTURUR). id yoksa no-op (signedIn kancası halleder).
  Future<void> onResumed(String uid) async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      final id = await _idStore.read();
      if (id == null || id.isEmpty) return; // henüz register edilmemiş
      final affected = await _repo.touchLastSeen(uid, id);
      if (affected == 0) {
        await _repo.register(uid, deviceId: id); // register-fallback
      }
    } catch (_) {
      // best-effort.
    } finally {
      _inFlight = false;
    }
  }
}
