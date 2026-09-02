/// Orchestrates raw file text → preview the user can confirm before anything is
/// written to the vault.
///
/// Parsing runs off the UI isolate; tests drive the synchronous core directly.
/// This layer never touches the vault itself — the caller applies the result via
/// `VaultCubit.addAll`, so a preview is always side-effect free.
library;

import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../../core/otp/otp_account.dart';
import 'backup_service.dart';
import 'dedupe.dart';
import 'import_exceptions.dart';
import 'import_format_detector.dart';
import 'import_models.dart';

/// Rewrites one account's issuer to its canonical catalog name. Must be PURE
/// and isolate-sendable: `preview` resolves it on the UI isolate and hands it
/// to the worker. `canonicalizerFor` in `dedupe.dart` builds one.
typedef AccountCanonicalizer = OtpAccount Function(OtpAccount account);

/// What the confirm screen renders: the accounts that would be added plus the
/// audit trail of everything that would not.
class ImportPreview {
  final ImportSource source;
  final List<OtpAccount> toAdd;
  final List<SkippedEntry> skipped;

  const ImportPreview({
    required this.source,
    required this.toAdd,
    this.skipped = const <SkippedEntry>[],
  });

  int get addCount => toAdd.length;

  /// Entries dropped because we already have them (in this file or in the vault)
  /// — reported separately from real failures, since they are not a problem.
  int get duplicateCount => skipped
      .where((e) =>
          e.reason == SkipReason.duplicateInFile ||
          e.reason == SkipReason.alreadyInVault)
      .length;

  /// Entries dropped because we could not import them (unsupported/invalid).
  int get skippedCount => skipped.length - duplicateCount;
}

class ImportService {
  /// Source parsers, tried after [detect] picks a format. Defaults to the empty
  /// set; DI wires the concrete parsers (`AegisParser`, `TwoFasParser`) — with
  /// none of them only our own encrypted backup format can be read.
  final List<ImportParser> parsers;

  final BackupService backup;

  /// Root-JSON fingerprinting. Injectable only so this service can be tested
  /// without the real detector; production always uses `detectSource`.
  final ImportSource Function(Map<String, dynamic> json) _detector;

  /// Duplicate identity function. Injectable for the same reason; production
  /// always uses `dedupeKey`.
  final String Function(OtpAccount account) _keyOf;

  /// Resolves the issuer canonicalizer for ONE preview run. Called on the UI
  /// isolate right before parsing, so a catalog refreshed between two imports
  /// is picked up, and so the closure that reaches the worker isolate captures
  /// only the immutable catalog snapshot — never the holder or its repository.
  ///
  /// WHY dedupe needs it (audit A2): `VaultCubit` rewrites an issuer to the
  /// catalog name as the token enters the vault ("github.com" → "GitHub"). If
  /// the preview deduped on the RAW issuer, re-importing that very file would
  /// see "github.com", miss the stored "GitHub" and add the token a second
  /// time. Both sides — the vault accounts AND the parsed entries — therefore
  /// go through the same rewrite before `keyOf` runs. null → no rewrite
  /// (legacy/test wiring; behaviour identical to before).
  final AccountCanonicalizer Function()? _canonicalizeResolver;

  /// [detector] and [keyOf] exist only so this service can be unit-tested in
  /// isolation; production wiring passes neither and gets `detectSource` /
  /// `dedupeKey`. [canonicalizeResolver] IS production wiring (locator binds it
  /// to the same `IssuerCatalogHolder` that `VaultCubit` uses).
  ImportService({
    List<ImportParser>? parsers,
    required this.backup,
    ImportSource Function(Map<String, dynamic> json)? detector,
    String Function(OtpAccount account)? keyOf,
    AccountCanonicalizer Function()? canonicalizeResolver,
  })  : parsers = parsers ?? const <ImportParser>[],
        _detector = detector ?? detectSource,
        _keyOf = keyOf ?? dedupeKey,
        _canonicalizeResolver = canonicalizeResolver;

  /// Hard ceiling on file size (8 MiB): a real export is orders of magnitude
  /// smaller, and the whole file is decoded in memory.
  static const int maxBytes = 8 * 1024 * 1024;

  /// Hard ceiling on ENTRIES in one import — accounts plus skipped entries
  /// (audit A3). The same 1024 the scanned Google path already enforces
  /// (`GoogleMigrationCollector.maxAccounts`), so no file can push more work
  /// into the preview list, the vault write and the push than a QR batch can.
  /// A file under [maxBytes] can still hold ~100k tiny entries, which is a real
  /// UI/memory hazard, and no genuine authenticator export comes close to 1024.
  static const int maxEntries = 1024;

  /// Decodes [raw] far enough to fingerprint it. Throws
  /// [MalformedImportFileException] when it is not a JSON object, and
  /// [ImportFileTooLargeException] before decoding an oversized file.
  ///
  /// Public (and cheap) on purpose: the UI calls it first so it can ask for the
  /// backup password only when the file actually is one of our own backups.
  ImportSource detect(String raw) => _detector(decodeRoot(raw));

  /// Parses, deduplicates against [existing] and returns the preview.
  /// [backupPassword] is required only for our own encrypted backup format;
  /// omitting it there is a programming error ([ArgumentError]) because [detect]
  /// lets the caller find out before ever calling this.
  Future<ImportPreview> preview({
    required String raw,
    required List<OtpAccount> existing,
    String? backupPassword,
  }) async {
    final root = decodeRoot(raw);
    final source = _detector(root);
    if (source == ImportSource.unknown) {
      throw const UnsupportedImportFormatException();
    }

    // Resolved HERE (UI isolate): the closure captures only the immutable
    // catalog snapshot, so it stays sendable to the worker below.
    final canonicalize = _canonicalizeResolver?.call();

    if (source == ImportSource.projectauthBackup) {
      if (backupPassword == null || backupPassword.isEmpty) {
        throw ArgumentError.value(backupPassword, 'backupPassword',
            'required for ${BackupService.formatId} files — call detect() first');
      }
      // Decryption cannot move to a worker isolate: the crypto service holds
      // native handles. Argon2id itself already runs isolated inside sodium.
      final payload =
          await backup.importDetailed(json: raw, password: backupPassword);
      return dedupeSync(
        ParsedImport(
          source: source,
          accounts: payload.accounts,
          skipped: payload.skipped,
        ),
        existing: existing,
        keyOf: _keyOf,
        canonicalize: canonicalize,
      );
    }

    // Everything below is pure CPU work on plain data → safe to move off the UI
    // isolate. Only sendable values are captured (no `this`, no plugins).
    final selected = parsers.where((p) => p.source == source).toList();
    final keyOf = _keyOf;
    return Isolate.run(() => parseAndDedupeSync(
          root: root,
          source: source,
          parsers: selected,
          existing: existing,
          keyOf: keyOf,
          canonicalize: canonicalize,
        ));
  }

  /// Dedupes an already-parsed import (no file, no JSON, no isolate).
  ///
  /// The Google Authenticator path produces its [ParsedImport] from scanned QR
  /// codes rather than from a file, so it enters the pipeline here instead of at
  /// [preview]. Merging a handful of QR batches is trivial CPU work, so it runs
  /// inline; the vault is still untouched — the caller applies the result.
  ///
  /// Throws [EmptyImportException] when [parsed] carried neither an account nor
  /// a skipped entry, matching the file path's contract.
  ImportPreview previewParsed(
    ParsedImport parsed, {
    required List<OtpAccount> existing,
  }) =>
      dedupeSync(
        parsed,
        existing: existing,
        keyOf: _keyOf,
        canonicalize: _canonicalizeResolver?.call(),
      );

  /// Size guard (UTF-8 bytes) → root JSON object. Shared by [detect] and
  /// [preview] so an oversized or unreadable file is rejected on both entries.
  ///
  /// Static because it uses no instance state: test doubles that
  /// `implements ImportService` then need not stub a pure JSON helper.
  @visibleForTesting
  static Map<String, dynamic> decodeRoot(String raw) {
    // `raw` is already a Dart String, so the meaningful ceiling is what it costs
    // as UTF-8 bytes (what the file actually was).
    final bytes = utf8.encode(raw).length;
    if (bytes > maxBytes) {
      throw ImportFileTooLargeException(bytes, maxBytes);
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const MalformedImportFileException('not valid JSON');
    }
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) {
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    }
    throw const MalformedImportFileException('root is not a JSON object');
  }

  /// The whole CPU-bound half of [preview] for non-backup sources: pick the
  /// parser, parse, deduplicate. Static and free of `this` so it can be sent to
  /// a worker isolate, and synchronous so tests can drive it directly.
  @visibleForTesting
  static ImportPreview parseAndDedupeSync({
    required Map<String, dynamic> root,
    required ImportSource source,
    required List<ImportParser> parsers,
    required List<OtpAccount> existing,
    required String Function(OtpAccount account) keyOf,
    AccountCanonicalizer? canonicalize,
  }) {
    ImportParser? parser;
    for (final candidate in parsers) {
      if (candidate.source == source) {
        parser = candidate;
        break;
      }
    }
    if (parser == null) {
      // Detected a format we have no parser wired for — same user-facing
      // outcome as an unrecognized file.
      throw const UnsupportedImportFormatException();
    }
    return dedupeSync(parser.parse(root),
        existing: existing, keyOf: keyOf, canonicalize: canonicalize);
  }

  /// Drops accounts already present in [existing] ([SkipReason.alreadyInVault])
  /// and repeats within the file ([SkipReason.duplicateInFile], first wins).
  ///
  /// Our own backups additionally match on the stable `id`, because they are the
  /// only source that preserves it — a restore over a partially synced vault
  /// must not clone tokens whose issuer/name the user has since edited.
  ///
  /// [EmptyImportException] is raised only when the file yielded NOTHING — no
  /// importable account and no skipped entry either. A file whose entries all
  /// turn out to be duplicates is not empty, and neither is one whose entries
  /// were all skipped by the parser (unsupported type, unreadable secret): the
  /// preview still has something worth showing, and telling the user WHICH
  /// entries were dropped and why beats a bare "nothing to import" (review
  /// follow-up). Such a preview has an empty `toAdd`, so the UI keeps the
  /// confirm button disabled.
  @visibleForTesting
  static ImportPreview dedupeSync(
    ParsedImport parsed, {
    required List<OtpAccount> existing,
    required String Function(OtpAccount account) keyOf,
    AccountCanonicalizer? canonicalize,
  }) {
    if (parsed.accounts.isEmpty && parsed.skipped.isEmpty) {
      throw const EmptyImportException();
    }

    // Entry ceiling (audit A3) — accounts AND skipped entries, exactly what
    // `GoogleMigrationCollector.maxAccounts` counts, so every import path (file,
    // encrypted backup, scanned QR) shares one limit. Checked before any per
    // entry work so an oversized file costs nothing beyond the parse.
    final entries = parsed.accounts.length + parsed.skipped.length;
    if (entries > maxEntries) {
      throw ImportTooManyEntriesException(entries, maxEntries);
    }

    // Canonicalize BOTH sides with the same function before any key is built:
    // the vault stores the catalog name, the file may carry an alias, and only
    // matching forms make `alreadyInVault` fire (audit A2). The accounts kept
    // in `toAdd` are the canonicalized ones, so what the preview shows is what
    // `VaultCubit.addAll` will store.
    final vaultAccounts =
        canonicalize == null ? existing : existing.map(canonicalize).toList();
    final parsedAccounts = canonicalize == null
        ? parsed.accounts
        : parsed.accounts.map(canonicalize).toList();

    final matchIds = parsed.source == ImportSource.projectauthBackup;
    final existingKeys = vaultAccounts.map(keyOf).toSet();
    final existingIds =
        matchIds ? vaultAccounts.map((a) => a.id).toSet() : const <String>{};

    final seenKeys = <String>{};
    final seenIds = <String>{};
    final toAdd = <OtpAccount>[];
    final skipped = <SkippedEntry>[...parsed.skipped];

    for (final account in parsedAccounts) {
      final key = keyOf(account);
      if (existingKeys.contains(key) ||
          (matchIds && existingIds.contains(account.id))) {
        skipped.add(SkippedEntry(
            reason: SkipReason.alreadyInVault, label: account.label));
        continue;
      }
      if (seenKeys.contains(key) || (matchIds && seenIds.contains(account.id))) {
        skipped.add(SkippedEntry(
            reason: SkipReason.duplicateInFile, label: account.label));
        continue;
      }
      seenKeys.add(key);
      if (matchIds) seenIds.add(account.id);
      toAdd.add(account);
    }

    return ImportPreview(
      source: parsed.source,
      toAdd: List<OtpAccount>.unmodifiable(toAdd),
      skipped: List<SkippedEntry>.unmodifiable(skipped),
    );
  }
}
