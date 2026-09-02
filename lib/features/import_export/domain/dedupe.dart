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
import '../../../core/ui/widgets/issuer_avatar.dart';
import '../../vault/domain/issuer_catalog.dart';

/// Builds the duplicate-detection key of [account] (plan §3.5).
///
/// Canonicalization rules:
/// - issuer: null and empty collapse to the same empty component, then reduced
///   to its `IssuerAvatar.slugFor` slug — lower-cased with every non
///   `[a-z0-9]` character removed. Exporters disagree on capitalization,
///   spacing and punctuation of the same service ("Amazon Web Services" vs
///   "amazon-web-services"), and the slug is exactly the normalization the
///   avatar and `IssuerCatalog` already use, so the three cannot diverge.
///   NOTE: the slug does NOT bridge an alias to its canonical name
///   ("github.com" slugs to `githubcom`, "GitHub" to `github`); only the
///   catalog knows those pairs, which is what [canonicalizerFor] is for.
/// - accountName: trimmed and lowercased for the same reason.
/// - secret: `Base32.decode` → `Base32.encode` round trip. `decode` already
///   ignores case, whitespace, dashes and `=` padding, and `encode` emits
///   upper-case without padding, so "jbswy3dp ehpk3pxp=" and "JBSWY3DPEHPK3PXP"
///   yield one key. The decode cannot fail here: `OtpAccount`'s constructor
///   validates the secret, so an instance with an undecodable secret cannot
///   exist.
///
/// KNOWN LIMIT: no Unicode NFC/NFD normalization. A precomposed "é" and its
/// decomposed form still produce different keys. Fixing it would need a
/// normalizer package, which we deliberately do not add for a duplicate hint.
///
/// The components are joined with a space. Since the slug rule strips spaces
/// out of the issuer, accountName is the only free-form part left, and a space
/// inside it can in principle collide with the separator. That is harmless: a
/// collision only means two entries that already differ solely by where a space
/// sits are treated as one duplicate, and the secret component (fixed alphabet,
/// no spaces) still separates genuinely different tokens.
///
/// [type], [digits], [period] and [counter] are intentionally NOT part of the
/// key: re-importing the same token after the user edited its digits, or an
/// HOTP counter that has since advanced, must still be recognized as "already
/// in the vault" instead of silently creating a second copy.
String dedupeKey(OtpAccount account) {
  final issuer = IssuerAvatar.slugFor((account.issuer ?? '').trim());
  final name = account.accountName.trim().toLowerCase();
  final secret = Base32.encode(Base32.decode(account.secret));
  return '$issuer $name $secret';
}

/// Builds the issuer canonicalizer bound to the [catalog] snapshot.
///
/// SINGLE SOURCE OF TRUTH: `VaultCubit` rewrites an issuer to its catalog name
/// on the way into the vault ("github.com" → "GitHub"), so dedupe MUST compare
/// the same rewritten form or a re-import of the very same token looks new and
/// lands in the vault twice. `ImportService` therefore canonicalizes both the
/// vault side and the parsed side before [dedupeKey] runs, and `VaultCubit`
/// delegates its own rewrite here.
///
/// The returned function is PURE and isolate-sendable: it captures only
/// [catalog] (an immutable slug → name map), never the holder or the
/// repository behind it, so `ImportService.preview` can hand it to the worker
/// isolate. Callers resolve a fresh snapshot per call, so a catalog refresh is
/// picked up on the next import.
///
/// An empty catalog (offline / not fetched yet) makes it a no-op — the issuer
/// is never invented, only aligned to a name the catalog already carries.
///
/// KNOWN LIMIT (accepted): canonicalization is therefore only as good as the
/// catalog snapshot at the moment of the write. A token stored as "GitHub"
/// while the catalog was loaded will NOT match a "github.com" imported while it
/// was empty — the alias half of the mapping is unavailable offline, and only
/// the slug reduction in [dedupeKey] still applies (which does happen to cover
/// this particular pair, but not an alias like "AWS" → "Amazon Web Services").
/// The fix would be to canonicalize lazily at comparison time against the
/// newest catalog, which costs a rewrite of the stored issuer; not worth it for
/// a duplicate the user can delete.
///
/// ASSUMPTION: canonicalization is applied ONCE, not to a fixed point. The
/// catalog must therefore never carry a chained alias (`a` → `b` and `b` → `c`)
/// — with one, two sides that entered at different links in the chain would
/// still disagree. Catalog rows are authored server-side; keep them flat.
OtpAccount Function(OtpAccount account) canonicalizerFor(IssuerCatalog catalog) =>
    (account) {
      final canon = catalog.canonicalIssuer(account.issuer);
      if (canon == null || canon == account.issuer) return account;
      return account.copyWith(issuer: canon);
    };
