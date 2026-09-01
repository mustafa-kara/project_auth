/// Password-encrypted backup of the whole vault (own format, not Aegis-compatible).
///
/// Filled by W2. Adds NO new crypto primitive: Argon2id + XChaCha20-Poly1305 via
/// [CryptoService], with `defaultKdfParams()` as the single source of cost values
/// (plan §4). The KDF parameters and salt are bound into the AEAD AAD
/// (`backup|1|<alg>|<ops>|<mem>|<salt>|<cipher>`), so an attacker cannot weaken
/// opslimit by editing the envelope.
library;

import 'package:flutter/foundation.dart';

import '../../../core/crypto/crypto_service.dart';
import '../../../core/otp/otp_account.dart';

class BackupService {
  final CryptoService _crypto;

  BackupService(this._crypto);

  /// Envelope discriminator; also the detector's fingerprint for our own files.
  static const String formatId = 'projectauth-backup';

  /// Highest envelope version this build can read. Newer → refused.
  static const int supportedVersion = 1;

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
  }) {
    throw UnimplementedError('W2 fills this');
  }

  /// Strictly validates the envelope, then decrypts. Wrong password or tampered
  /// bytes → `WrongBackupPasswordException`; version > [supportedVersion] →
  /// `UnsupportedBackupVersionException`.
  Future<List<OtpAccount>> import({
    required String json,
    required String password,
  }) {
    throw UnimplementedError('W2 fills this');
  }
}
