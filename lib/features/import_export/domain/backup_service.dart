/// Password-encrypted backup of the whole vault (own format, not Aegis-compatible).
///
/// Adds NO new crypto primitive: Argon2id + XChaCha20-Poly1305 via
/// [CryptoService], with `defaultKdfParams()` as the single source of cost values
/// (plan §4). The KDF parameters and salt are bound into the AEAD AAD
/// (`backup|1|<alg>|<ops>|<mem>|<salt>|<cipher>`), so an attacker cannot weaken
/// opslimit by editing the envelope.
///
/// The backup password is INDEPENDENT of the master password: this file must be
/// openable on a device that has no vault yet, so it cannot be tied to the key
/// hierarchy. It is held to the same policy (`KeyManager.enforcePolicy`).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/crypto/crypto_exceptions.dart';
import '../../../core/crypto/crypto_service.dart';
import '../../../core/crypto/key_handle.dart';
import '../../../core/otp/otp_account.dart';
import '../../auth/domain/key_manager.dart';
import 'backup_envelope.dart';
import 'import_exceptions.dart';
import 'import_models.dart';

/// Decrypted backup contents: the accounts that survived parsing plus the audit
/// trail of the records that did not.
///
/// Exists because [BackupService.import] deliberately returns only the usable
/// accounts, while the import preview also has to tell the user how many records
/// were dropped. Both come from one decrypt — see [BackupService.importDetailed].
class BackupPayload {
  /// `exportedAt` from the encrypted payload. null when the field was missing or
  /// unparseable — it is informational only and never gates the restore.
  final DateTime? exportedAt;

  final List<OtpAccount> accounts;

  /// One [SkipReason.invalidFields] entry per record that failed to parse.
  final List<SkippedEntry> skipped;

  const BackupPayload({
    required this.accounts,
    this.exportedAt,
    this.skipped = const <SkippedEntry>[],
  });
}

class BackupService {
  final CryptoService _crypto;

  BackupService(this._crypto);

  /// Envelope discriminator; also the detector's fingerprint for our own files.
  static const String formatId = BackupEnvelope.formatId;

  /// Highest envelope version this build can read. Newer → refused.
  static const int supportedVersion = BackupEnvelope.supportedVersion;

  /// Exposed so W2's implementation and its fakes share one accessor; the field
  /// stays private so the crypto backend cannot be swapped after construction.
  @visibleForTesting
  CryptoService get crypto => _crypto;

  /// Returns the serialized envelope JSON. [password] is checked against the
  /// master-password policy; [now] is injectable for deterministic tests.
  /// The derived KEK is disposed and the plaintext zero-filled in a `finally`.
  Future<String> export({
    required List<OtpAccount> accounts,
    required String password,
    DateTime? now,
  }) async {
    // Reject a weak password before spending Argon2id on it — same gate and same
    // messages as vault setup (docs/CRYPTO.md §7).
    KeyManager.enforcePolicy(password);

    final params = _crypto.defaultKdfParams();
    final salt = _crypto.randomBytes(params.saltBytes);
    final createdAt = (now ?? DateTime.now()).toUtc();

    final plaintext = Uint8List.fromList(utf8.encode(jsonEncode({
      'exportedAt': createdAt.toIso8601String(),
      'accounts': accounts.map((a) => a.toJson()).toList(growable: false),
    })));

    KeyHandle? kek;
    try {
      kek = await _crypto.deriveKek(
        password: password,
        salt: salt,
        opsLimit: params.opsLimit,
        memLimit: params.memLimit,
      );
      final blob = _crypto.encrypt(
        plaintext: plaintext,
        key: kek,
        aad: BackupEnvelope.aadFor(
          kdfAlg: BackupEnvelope.kdfAlgArgon2id,
          opsLimit: params.opsLimit,
          memLimit: params.memLimit,
          salt: salt,
          cipherAlg: BackupEnvelope.cipherAlgXChaCha20,
        ),
      );
      final envelope = BackupEnvelope(
        createdAt: createdAt,
        opsLimit: params.opsLimit,
        memLimit: params.memLimit,
        salt: salt,
        blob: blob,
      );
      return jsonEncode(envelope.toJson());
    } finally {
      kek?.dispose();
      // Best effort: this buffer is wiped, but the intermediate JSON String and
      // the encoder's internal buffers stay on the GC heap until collected —
      // Dart offers no way to pin or wipe them (documented in CRYPTO.md §16).
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  /// Strictly validates the envelope, then decrypts. Wrong password or tampered
  /// bytes → [WrongBackupPasswordException]; version > [supportedVersion] →
  /// [UnsupportedBackupVersionException].
  ///
  /// Returns only the records that parsed. Use [importDetailed] when the caller
  /// also needs to report how many were dropped.
  Future<List<OtpAccount>> import({
    required String json,
    required String password,
  }) async =>
      (await importDetailed(json: json, password: password)).accounts;

  /// [import] plus the skipped-record audit trail. Separate method rather than a
  /// changed [import] signature: restore callers want the simple list, while the
  /// import preview needs the drop count for the same single decrypt.
  Future<BackupPayload> importDetailed({
    required String json,
    required String password,
  }) async {
    final envelope = parseEnvelope(json);

    KeyHandle? kek;
    Uint8List? plaintext;
    try {
      // The file's OWN parameters are used — they are authenticated by the AAD,
      // so a downgraded opslimit cannot survive the tag check below.
      kek = await _crypto.deriveKek(
        password: password,
        salt: envelope.salt,
        opsLimit: envelope.opsLimit,
        memLimit: envelope.memLimit,
      );
      try {
        plaintext = _crypto.decrypt(
          blob: envelope.blob,
          key: kek,
          aad: envelope.aad,
        );
      } on DecryptException {
        // AEAD cannot distinguish a wrong password from tampering — by design.
        throw const WrongBackupPasswordException();
      }
      return parsePayload(plaintext);
    } finally {
      kek?.dispose();
      if (plaintext != null) plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  /// Decodes and strictly validates the envelope WITHOUT deriving a key.
  /// Malformed → [FormatException]; too new → [UnsupportedBackupVersionException].
  @visibleForTesting
  BackupEnvelope parseEnvelope(String json) {
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      throw const FormatException('BackupService: file is not valid JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('BackupService: root must be a JSON object');
    }
    return BackupEnvelope.fromJson(
      decoded,
      onUnsupportedVersion: (v) => throw UnsupportedBackupVersionException(v),
    );
  }

  /// Parses the decrypted payload. A single malformed record is recorded as a
  /// [SkipReason.invalidFields] entry instead of failing the whole restore —
  /// one bad row must never cost the user the other 40 tokens.
  @visibleForTesting
  BackupPayload parsePayload(Uint8List plaintext) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(plaintext));
    } on FormatException {
      throw const FormatException('BackupService: backup payload is not valid JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('BackupService: backup payload must be an object');
    }
    final rawAccounts = decoded['accounts'];
    if (rawAccounts is! List) {
      throw const FormatException('BackupService: "accounts" must be a list');
    }

    final exportedAtText = decoded['exportedAt'];
    final accounts = <OtpAccount>[];
    final skipped = <SkippedEntry>[];
    for (final entry in rawAccounts) {
      if (entry is! Map) {
        skipped.add(const SkippedEntry(reason: SkipReason.invalidFields));
        continue;
      }
      final map = entry is Map<String, dynamic>
          ? entry
          : entry.map((k, v) => MapEntry(k.toString(), v));
      try {
        accounts.add(OtpAccount.fromJson(map));
      } on FormatException {
        // Best-effort label only; the secret is never read into the audit trail.
        skipped.add(SkippedEntry(reason: SkipReason.invalidFields, label: _label(map)));
      }
    }

    return BackupPayload(
      exportedAt:
          exportedAtText is String ? DateTime.tryParse(exportedAtText) : null,
      accounts: accounts,
      skipped: skipped,
    );
  }

  /// "Issuer (account)" for a record we could not build an [OtpAccount] from.
  /// Returns null when neither field is a usable String — never a secret.
  static String? _label(Map<String, dynamic> json) {
    final issuer = json['issuer'];
    final account = json['accountName'];
    final i = issuer is String && issuer.isNotEmpty ? issuer : null;
    final a = account is String && account.isNotEmpty ? account : null;
    if (i != null && a != null) return '$i ($a)';
    return i ?? a;
  }
}
