/// On-disk shape of a password-encrypted vault backup (plan §4.1) plus the AAD
/// derivation that binds the KDF cost parameters to the ciphertext (plan §4.2).
///
/// The envelope is a plain JSON object; only `ciphertext` is secret. Everything
/// else (KDF algorithm, opslimit, memlimit, salt, cipher algorithm) is public
/// metadata an attacker can see AND edit — which is exactly why those fields are
/// fed into the AEAD's additional data instead of being trusted blindly. Editing
/// `opslimit` down to 1 to make a brute-force cheaper changes the AAD, so the
/// tag no longer verifies and the file simply fails to open.
///
/// The AAD is therefore NOT stored in the file: it is recomputed from the
/// envelope on every read. A stored `aad` field would be attacker-controlled and
/// would defeat the whole construction.
///
/// SECURITY: this type never sees the password or the derived key. Validation is
/// strict and happens before anything reaches sodium (docs/CRYPTO.md §8), so a
/// corrupt or future-version file reports a format error instead of looking like
/// a wrong password.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../../core/crypto/encrypted_blob.dart';

class BackupEnvelope {
  /// Discriminator written into `format`; also the detector's fingerprint.
  static const String formatId = 'projectauth-backup';

  /// Highest envelope version this build can read.
  static const int supportedVersion = 1;

  /// The only KDF this format allows. A future algorithm needs a version bump.
  static const String kdfAlgArgon2id = 'argon2id';

  /// The only AEAD this format allows (matches `CryptoService`).
  static const String cipherAlgXChaCha20 = 'xchacha20poly1305-ietf';

  /// `crypto_pwhash_SALTBYTES` — same constant the key hierarchy uses.
  static const int saltBytes = 16;

  /// Argon2id cost bounds accepted on read. The lower bounds stop a downgrade to
  /// a trivially brute-forceable cost; the upper bounds stop a denial-of-service
  /// file that would ask sodium for an absurd allocation.
  static const int minOpsLimit = 1;
  static const int maxOpsLimit = 10;
  static const int minMemLimit = 8 * 1024 * 1024;
  static const int maxMemLimit = 1024 * 1024 * 1024;

  final int version;
  final DateTime createdAt;
  final String kdfAlg;
  final int opsLimit;
  final int memLimit;
  final Uint8List _salt;
  final String cipherAlg;

  /// nonce + ciphertext. Reuses [EncryptedBlob]'s own length validation.
  final EncryptedBlob blob;

  BackupEnvelope({
    this.version = supportedVersion,
    required this.createdAt,
    this.kdfAlg = kdfAlgArgon2id,
    required this.opsLimit,
    required this.memLimit,
    required Uint8List salt,
    this.cipherAlg = cipherAlgXChaCha20,
    required this.blob,
  }) : _salt = Uint8List.fromList(salt) {
    _validate(
      version: version,
      kdfAlg: kdfAlg,
      opsLimit: opsLimit,
      memLimit: memLimit,
      saltLength: _salt.length,
      cipherAlg: cipherAlg,
    );
  }

  /// Defensive copy — callers cannot mutate the salt behind the AAD.
  Uint8List get salt => Uint8List.fromList(_salt);

  /// Canonical base64 of the salt, as written to the file and fed to the AAD.
  ///
  /// Always re-encoded from the decoded bytes rather than echoing the string
  /// found in the file: a non-canonical encoding must not be able to produce a
  /// different AAD for identical salt bytes.
  String get saltBase64 => base64Encode(_salt);

  /// `backup|<version>|<kdf.alg>|<opslimit>|<memlimit>|<b64 salt>|<cipher.alg>`
  Uint8List get aad => aadFor(
        version: version,
        kdfAlg: kdfAlg,
        opsLimit: opsLimit,
        memLimit: memLimit,
        salt: _salt,
        cipherAlg: cipherAlg,
      );

  /// Same derivation as [aad], usable before the ciphertext (and therefore the
  /// envelope) exists — export needs the AAD to produce the blob.
  static Uint8List aadFor({
    int version = supportedVersion,
    required String kdfAlg,
    required int opsLimit,
    required int memLimit,
    required Uint8List salt,
    required String cipherAlg,
  }) {
    final text = 'backup|$version|$kdfAlg|$opsLimit|$memLimit|'
        '${base64Encode(salt)}|$cipherAlg';
    return Uint8List.fromList(utf8.encode(text));
  }

  Map<String, dynamic> toJson() => {
        'format': formatId,
        'version': version,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'kdf': {
          'alg': kdfAlg,
          'opslimit': opsLimit,
          'memlimit': memLimit,
          'salt': saltBase64,
        },
        'cipher': {
          'alg': cipherAlg,
          'nonce': base64Encode(blob.nonce),
        },
        'ciphertext': base64Encode(blob.ciphertext),
      };

  /// Strict parse of a decoded root JSON object.
  ///
  /// Throws [FormatException] for anything malformed. A version newer than
  /// [supportedVersion] is signalled by [onUnsupportedVersion] instead, so the
  /// caller can raise its own user-facing exception without this layer having to
  /// know about the import error model.
  factory BackupEnvelope.fromJson(
    Map<String, dynamic> json, {
    Never Function(int version)? onUnsupportedVersion,
  }) {
    final format = _asString(json['format'], 'format');
    if (format != formatId) {
      throw FormatException(
          'BackupEnvelope: "format" must be "$formatId" (got "$format")');
    }

    final version = _asInt(json['version'], 'version');
    if (version == null || version < 1) {
      throw FormatException('BackupEnvelope: invalid "version" ($version)');
    }
    if (version > supportedVersion) {
      if (onUnsupportedVersion != null) onUnsupportedVersion(version);
      throw FormatException(
          'BackupEnvelope: unsupported "version" $version (max $supportedVersion)');
    }

    final createdAtText = _asString(json['createdAt'], 'createdAt');
    if (createdAtText == null) {
      throw const FormatException('BackupEnvelope: "createdAt" is required');
    }
    final createdAt = DateTime.tryParse(createdAtText);
    if (createdAt == null) {
      throw const FormatException(
          'BackupEnvelope: "createdAt" is not an ISO-8601 timestamp');
    }

    final kdf = _asMap(json['kdf'], 'kdf');
    final cipher = _asMap(json['cipher'], 'cipher');

    final kdfAlg = _asString(kdf['alg'], 'kdf.alg');
    final opsLimit = _asInt(kdf['opslimit'], 'kdf.opslimit');
    final memLimit = _asInt(kdf['memlimit'], 'kdf.memlimit');
    if (kdfAlg == null || opsLimit == null || memLimit == null) {
      throw const FormatException(
          'BackupEnvelope: "kdf.alg"/"kdf.opslimit"/"kdf.memlimit" are required');
    }
    final salt = _base64(_required(kdf['salt'], 'kdf.salt'), 'kdf.salt');
    final cipherAlg = _asString(cipher['alg'], 'cipher.alg');
    if (cipherAlg == null) {
      throw const FormatException('BackupEnvelope: "cipher.alg" is required');
    }
    final nonce = _base64(_required(cipher['nonce'], 'cipher.nonce'), 'cipher.nonce');
    final ciphertext =
        _base64(_required(json['ciphertext'], 'ciphertext'), 'ciphertext');

    return BackupEnvelope(
      version: version,
      createdAt: createdAt,
      kdfAlg: kdfAlg,
      opsLimit: opsLimit,
      memLimit: memLimit,
      salt: salt,
      cipherAlg: cipherAlg,
      // Length rules for nonce (24) / ciphertext (>=16) live in EncryptedBlob.
      blob: EncryptedBlob(nonce: nonce, ciphertext: ciphertext),
    );
  }

  static void _validate({
    required int version,
    required String kdfAlg,
    required int opsLimit,
    required int memLimit,
    required int saltLength,
    required String cipherAlg,
  }) {
    if (version < 1 || version > supportedVersion) {
      throw FormatException(
          'BackupEnvelope: unsupported version $version (expected 1..$supportedVersion)');
    }
    if (kdfAlg != kdfAlgArgon2id) {
      throw FormatException(
          'BackupEnvelope: "kdf.alg" must be "$kdfAlgArgon2id" (got "$kdfAlg")');
    }
    if (cipherAlg != cipherAlgXChaCha20) {
      throw FormatException(
          'BackupEnvelope: "cipher.alg" must be "$cipherAlgXChaCha20" (got "$cipherAlg")');
    }
    if (opsLimit < minOpsLimit || opsLimit > maxOpsLimit) {
      throw FormatException(
          'BackupEnvelope: "kdf.opslimit" must be $minOpsLimit..$maxOpsLimit (got $opsLimit)');
    }
    if (memLimit < minMemLimit || memLimit > maxMemLimit) {
      throw FormatException(
          'BackupEnvelope: "kdf.memlimit" must be $minMemLimit..$maxMemLimit (got $memLimit)');
    }
    if (saltLength != saltBytes) {
      throw FormatException(
          'BackupEnvelope: "kdf.salt" must be exactly $saltBytes bytes (got $saltLength)');
    }
  }

  static Object _required(Object? v, String name) {
    if (v == null) throw FormatException('BackupEnvelope: "$name" is required');
    return v;
  }

  static Uint8List _base64(Object value, String name) {
    if (value is! String) {
      throw FormatException(
          'BackupEnvelope: "$name" must be a String (got ${value.runtimeType})');
    }
    try {
      return base64Decode(value);
    } on FormatException {
      throw FormatException('BackupEnvelope: "$name" is not valid base64');
    }
  }

  static String? _asString(Object? v, String name) {
    if (v == null) return null;
    if (v is String) return v;
    throw FormatException(
        'BackupEnvelope: "$name" must be a String (got ${v.runtimeType})');
  }

  /// Integer-valued doubles (`3.0`) are accepted; a fractional `num` is rejected
  /// rather than silently truncated (docs/CRYPTO.md §8).
  static int? _asInt(Object? v, String name) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) {
      if (v == v.truncateToDouble()) return v.toInt();
      throw FormatException(
          'BackupEnvelope: "$name" must be an integer (fractional: $v)');
    }
    throw FormatException(
        'BackupEnvelope: "$name" must be a number (got ${v.runtimeType})');
  }

  static Map<String, dynamic> _asMap(Object? v, String name) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return v.map((k, val) => MapEntry(k.toString(), val));
    throw FormatException(
        'BackupEnvelope: "$name" must be an object (got ${v.runtimeType})');
  }
}
