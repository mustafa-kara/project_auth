/// Canonical identity of an account for duplicate detection.
///
/// Filled by W1. The key is issuer + accountName + canonicalized Base32 secret
/// (decode/re-encode) so padding and case differences between exporters do not
/// create false "new" tokens. Used for both in-file and against-vault dedupe.
///
/// SECURITY: the returned key CONTAINS the secret — it is an in-memory
/// comparison value only and must never be logged, persisted or shown in UI.
library;

import '../../../core/otp/base32.dart';
import '../../../core/otp/otp_account.dart';

/// Builds the duplicate-detection key of [account] (plan §3.5).
///
/// Canonicalization rules:
/// - issuer: null and empty collapse to the same empty component, trimmed and
///   lowercased (exporters disagree on capitalization of the same service).
/// - accountName: trimmed and lowercased for the same reason.
/// - secret: `Base32.decode` → `Base32.encode` round trip. `decode` already
///   ignores case, whitespace, dashes and `=` padding, and `encode` emits
///   upper-case without padding, so "jbswy3dp ehpk3pxp=" and "JBSWY3DPEHPK3PXP"
///   yield one key. The decode cannot fail here: `OtpAccount`'s constructor
///   validates the secret, so an instance with an undecodable secret cannot
///   exist.
///
/// The components are joined with a space; issuer and accountName are the only
/// free-form parts and a space inside one of them can in principle collide with
/// the separator. That is harmless: a collision only means two entries that
/// already differ solely by where a space sits are treated as one duplicate,
/// and the secret component (fixed alphabet, no spaces) still separates
/// genuinely different tokens.
///
/// [type], [digits], [period] and [counter] are intentionally NOT part of the
/// key: re-importing the same token after the user edited its digits, or an
/// HOTP counter that has since advanced, must still be recognized as "already
/// in the vault" instead of silently creating a second copy.
String dedupeKey(OtpAccount account) {
  final issuer = (account.issuer ?? '').trim().toLowerCase();
  final name = account.accountName.trim().toLowerCase();
  final secret = Base32.encode(Base32.decode(account.secret));
  return '$issuer $name $secret';
}
