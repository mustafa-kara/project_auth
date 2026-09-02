/// Faz 3 Patch 3 — token sync için **ham** (decrypt edilmemiş) kayıt portu.
///
/// `EncryptedVaultRepository`'nin çözülmüş `OtpAccount` arayüzü (`VaultRepository`)
/// DEĞİŞMEZ; sync, opak ciphertext/nonce/metadata'ya masterKey OLMADAN erişmek için
/// AYRI bir port kullanır (`RawTokenStore`). Böylece 293 test + VaultCubit sözleşmesi
/// bozulmaz, sync katmanı masterKey görmez (güvenlik yüzeyi dar).
///
/// `RawTokenRecord` lokal `_TokenRecord`'un public hâli + sunucu cursor'u (`sv`):
/// sunucu `updated_at` (LWW hakemi). Lokal `updatedAtMs` (client epoch-ms) YALNIZ
/// "lokal değişiklik oldu mu" + push stamp için; merge kararında ASLA kullanılmaz.
library;

import '../../../core/crypto/encrypted_blob.dart';
import 'remote_token_repository.dart';

/// Diskteki tek token kaydının ham (opak) temsili — decrypt YOK.
class RawTokenRecord {
  final String id;
  final int version;
  final EncryptedBlob blob;

  /// Client epoch-ms (lokal bookkeeping + push stamp). **Merge kararında kullanılmaz.**
  final int updatedAtMs;

  /// Soft-delete tombstone bayrağı (sunucuya `deleted=true` gider; `load()`
  /// hesaplarda göstermez).
  final bool deleted;

  /// Bu kaydın en son uzlaşıldığı SUNUCU `updated_at`'i (ISO-8601 UTC). null =
  /// hiç sync edilmemiş / lokal-dirty (push beklemede). LWW + echo ayrımı bununla yapılır.
  final String? serverUpdatedAtIso;

  const RawTokenRecord({
    required this.id,
    required this.blob,
    required this.updatedAtMs,
    this.version = 1,
    this.deleted = false,
    this.serverUpdatedAtIso,
  });

  /// `serverUpdatedAtIso == null` → lokal değişiklik henüz sunucuya push edilmemiş.
  bool get isDirty => serverUpdatedAtIso == null;

  RawTokenRecord copyWith({
    int? version,
    EncryptedBlob? blob,
    int? updatedAtMs,
    bool? deleted,
    String? serverUpdatedAtIso,
    bool clearServerUpdatedAt = false,
  }) => RawTokenRecord(
    id: id,
    version: version ?? this.version,
    blob: blob ?? this.blob,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    deleted: deleted ?? this.deleted,
    serverUpdatedAtIso: clearServerUpdatedAt
        ? null
        : (serverUpdatedAtIso ?? this.serverUpdatedAtIso),
  );
}

/// `importRemote` sonucu — cursor bilgisi TAŞIMAZ (cursor `RemotePullResult.
/// safeCursorIso`'dan `TokenSyncService` tarafında ilerletilir).
class TokenMergeOutcome {
  /// Disk değişti mi → `VaultCubit.reloadFromStore()` tetiklenir.
  final bool changed;

  /// Uygulanan (overwrite/ekleme) remote satır sayısı (telemetri/test).
  final int appliedCount;

  const TokenMergeOutcome({required this.changed, required this.appliedCount});

  static const none = TokenMergeOutcome(changed: false, appliedCount: 0);
}

/// Ham token deposu portu — `EncryptedVaultRepository` tarafından implement edilir.
/// **masterKey GEREKTİRMEZ** (opak ciphertext'i açmadan okur/yazar).
abstract interface class RawTokenStore {
  /// Diskteki TÜM kayıtları (canlı + tombstone; bozuk-raw HARİÇ) ham olarak döndürür.
  Future<List<RawTokenRecord>> exportRaw();

  /// Remote satırları LWW ile diske merge eder (masterKey YOK). [pullCursorIso] =
  /// pull'a başlanan andaki sunucu cursor'u (dirty-vs-echo ayrımı için ŞART).
  Future<TokenMergeOutcome> importRemote(
    List<RemoteTokenRow> remote, {
    required String? pullCursorIso,
  });

  /// [id]'yi soft-delete tombstone'a çevirir (son bilinen blob + `deleted=true` +
  /// taze `updatedAtMs` + `sv=null`) ve canlılarla birlikte diske ATOMİK yazar.
  Future<void> markDeleted(String id);
}
