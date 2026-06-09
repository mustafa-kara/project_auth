/// Bulut senkron katmanı domain hataları (Faz 3 Patch 2).
///
/// `SupabaseKeyAttributesRepository` PostgREST (`PostgrestException`) ve ağ
/// hatalarını bu tiplere eşler — VaultLockCubit/UI yalnız domain hatalarını
/// tanır, doğrudan Supabase tiplerine bağımlı kalmaz.
///
/// **KRİTİK ayrım (restore):** `SyncError` (ağ/RLS/format) ile gerçek "0-row"
/// KESİN ayrılır — repository `fetch` 0-row'da `null` döner, hata durumunda
/// `SyncError` FIRLATIR. bootstrap bunu yanlış sınıflarsa kullanıcı sunucuda
/// attrs varken setup'a düşebilir (çift-vault riski) → ağ hatası ASLA 0-row gibi
/// ele alınmaz.
library;

sealed class SyncError implements Exception {
  const SyncError(this.message);
  final String message;
  @override
  String toString() => '$runtimeType: $message';
}

/// Ağ/bağlantı hatası (`AuthRetryableFetchException`, socket, timeout).
/// Restore'da bu → `restoreFailed` (setup'a DÜŞME).
class SyncNetworkError extends SyncError {
  const SyncNetworkError(
      [super.message = 'Bağlantı hatası. İnternetini kontrol et.']);
}

/// Yetki reddi (RLS/401/403) — beklenmedik; oturum/uid uyumsuzluğu olabilir.
class SyncPermissionDenied extends SyncError {
  const SyncPermissionDenied([super.message = 'Yetki reddedildi.']);
}

/// Sunucu kaydı beklenen kolon/formatta değil (bytea decode / eksik alan).
class SyncMalformedRemote extends SyncError {
  const SyncMalformedRemote(
      [super.message = 'Sunucu verisi beklenmeyen biçimde.']);
}

/// Eşleştirilemeyen diğer hatalar.
class SyncUnknownError extends SyncError {
  const SyncUnknownError([super.message = 'Beklenmeyen bir senkron hatası.']);
}
