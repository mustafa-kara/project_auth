/// Uzaktan özellik bayrakları sunucu deposu — soyutlama (Faz 3 Patch 4).
///
/// `feature_flags` tablosu (public read; anon+authenticated SELECT). Yalnız OKUNUR.
/// Sunucu şeması DEĞİŞMEZ. E2E'ye DOKUNMAZ. Realtime YOK → fetch-on-signedIn + cache.
library;

import 'sync_exceptions.dart';

class FeatureFlag {
  final String key;
  final bool enabled;
  final Map<String, dynamic>? payload;

  const FeatureFlag({required this.key, required this.enabled, this.payload});

  /// Sunucu/cache satırı → model. Throws [FormatException] on bad data.
  static FeatureFlag fromJson(Map<String, dynamic> json) {
    final key = json['key'];
    final enabled = json['enabled'];
    if (key is! String) {
      throw FormatException(
        'feature_flags.key String bekleniyordu (${key.runtimeType})',
      );
    }
    if (enabled is! bool) {
      throw FormatException(
        'feature_flags.enabled bool bekleniyordu (${enabled.runtimeType})',
      );
    }
    final payload = json['payload'];
    return FeatureFlag(
      key: key,
      enabled: enabled,
      payload: payload is Map<String, dynamic> ? payload : null,
    );
  }
}

abstract interface class FeatureFlagsRepository {
  /// Tüm flag'leri çeker (public read). Ağ/izin hatası → [SyncError].
  Future<List<FeatureFlag>> fetchAll();
}
