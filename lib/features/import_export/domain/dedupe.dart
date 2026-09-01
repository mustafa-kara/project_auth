/// Canonical identity of an account for duplicate detection.
///
/// Filled by W1. The key is issuer + accountName + canonicalized Base32 secret
/// (decode/re-encode) so padding and case differences between exporters do not
/// create false "new" tokens. Used for both in-file and against-vault dedupe.
///
/// SECURITY: the returned key CONTAINS the secret — it is an in-memory
/// comparison value only and must never be logged, persisted or shown in UI.
library;

import '../../../core/otp/otp_account.dart';

String dedupeKey(OtpAccount account) {
  throw UnimplementedError('W1 fills this');
}
