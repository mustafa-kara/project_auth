/// Bir OTP hesabını (TOTP/HOTP/Steam) temsil eden değişmez model.
///
/// `otpauth://` URI'sinden parse edilir ve tekrar serialize edilebilir.
/// Bu model şifrelenecek "açık" veridir; Faz 2'de masterKey ile sarmalanır.
library;

import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:uuid/uuid.dart';

import 'base32.dart';
import 'otp_algorithm.dart';

enum OtpType { totp, hotp, steam }

const _uuid = Uuid();

class OtpAccount extends Equatable {
  /// Stabil benzersiz kimlik (uuid v4). ARCHITECTURE §7.5: token Faz 1'den itibaren
  /// stabil `id` taşır → Faz 3 lokal→bulut backfill'inde idempotent upsert (duplicate
  /// önleme) bu id'ye dayanır. Liste reorder/silme sonrası UI state reuse'u da bu id'ye
  /// göre `ValueKey` ile çözülür. Verilmezse üretimde rastgele atanır.
  final String id;

  /// Base32 secret (ham haliyle saklanır; decode [secretBytes] ile yapılır).
  final String secret;
  final OtpType type;
  final String? issuer;
  final String accountName;
  final OtpAlgorithm algorithm;
  final int digits;
  final int period; // TOTP/Steam için saniye
  final int counter; // HOTP için sayaç

  /// Phase 5 Patch 3 — user labels, in the order the user put them.
  ///
  /// Always normalized (see [normalizeTags]) and always unmodifiable, so no
  /// caller can push a 9th tag or a blank one into an already built account.
  ///
  /// K1 — NO record version bump. Tags live INSIDE the encrypted token blob;
  /// the record `v`, the AAD (`token|1|<id>`) and the backup envelope `version`
  /// are unchanged. Bumping `v` would make every older client reject the WHOLE
  /// vault ("açılamadı") instead of quietly ignoring one unknown key.
  ///
  /// K2 — [toJson] omits the key entirely when the list is empty, so an
  /// untagged account serializes byte-identically to a pre-Patch-3 one. No
  /// re-encrypt wave, no `updatedAt` churn, no sync storm on upgrade.
  ///
  /// K3 — tags ARE in [props] (see the note there): the repository's
  /// unchanged-blob shortcut compares `prev.account == account`
  /// (`encrypted_vault_repository.dart:219`), so leaving them out would make an
  /// edit that changed ONLY tags reuse the old ciphertext — the change would
  /// vanish on the next load and never reach the cloud.
  ///
  /// K4 — the model normalizes rather than rejects; only a type error is fatal
  /// (see [fromJson]). Import sources hand over arbitrary group names and a
  /// thrown exception there would drop an otherwise valid token.
  ///
  /// K5 — tags are NOT part of `dedupeKey` (`import_export/domain/dedupe.dart`):
  /// the same secret imported with a different group is still the same token.
  ///
  /// R1 (accepted, documented): an older client that EDITS a tagged token drops
  /// the key it never read, so the tags are lost on every device.
  final List<String> tags;

  /// Ceiling on tags per account. Beyond this the extras are dropped, never
  /// an exception (K4).
  static const int maxTags = 8;

  /// Ceiling on the length of ONE tag, counted in runes (user-perceived code
  /// points) rather than UTF-16 units, so an emoji or a combining Turkish
  /// character is not cut in half.
  static const int maxTagRunes = 32;

  OtpAccount({
    String? id,
    required this.secret,
    required this.type,
    required this.accountName,
    this.issuer,
    this.algorithm = OtpAlgorithm.sha1,
    this.digits = 6,
    this.period = 30,
    this.counter = 0,
    List<String> tags = const [],
  }) : id = id ?? _uuid.v4(),
       tags = normalizeTags(tags) {
    // TEK doğrulama noktası: parse, fromJson ve doğrudan kurulum hepsi buradan
    // geçer → geçersiz bir OtpAccount HİÇBİR yoldan oluşamaz (kart render/timer'da
    // geç crash yerine kaynakta FormatException). otpauth:// parser'ı ayrıca
    // string-düzeyi kontroller (sayı mı, vb.) yapar; bu, değer-aralığı son savunması.
    validate();
  }

  /// Alan değerlerinin OTP üretimi için güvenli aralıkta olduğunu doğrular.
  /// Geçersizse [FormatException]. (Hem `otpauth://` parse hem JSON yükleme
  /// hem de programatik kurulum için ortak güvenlik kapısı.)
  void validate() {
    // secret Base32 olarak çözülebilmeli ve boş olmamalı (yoksa secretBytes
    // kart render'ında FormatException atar).
    final Uint8List bytes;
    try {
      bytes = Base32.decode(secret);
    } on FormatException {
      throw const FormatException('OtpAccount: "secret" geçerli Base32 değil');
    }
    if (bytes.isEmpty) {
      throw const FormatException('OtpAccount: "secret" boş/çözülemedi');
    }
    // digits: Steam 5 (kendi kodlaması), aksi halde 6–8.
    if (type == OtpType.steam) {
      if (digits != 5) {
        throw FormatException(
          'OtpAccount: Steam "digits" 5 olmalı (verilen $digits)',
        );
      }
    } else if (digits < 6 || digits > 8) {
      throw FormatException(
        'OtpAccount: "digits" 6..8 olmalı (verilen $digits)',
      );
    }
    // period: TOTP/Steam için >0 (secondsRemaining/totp bölme yapar). HOTP'te
    // kullanılmaz ama yine de anlamsız negatifi reddet.
    if (period < 1 || period > 600) {
      throw FormatException(
        'OtpAccount: "period" 1..600 olmalı (verilen $period)',
      );
    }
    // counter: negatif olamaz.
    if (counter < 0) {
      throw FormatException(
        'OtpAccount: "counter" negatif olamaz (verilen $counter)',
      );
    }
  }

  /// Cleans an arbitrary tag list into the canonical shape stored on an account.
  ///
  /// NEVER throws — every rule below drops or shortens, so a hostile import file
  /// or a fat-fingered edit can shrink the list but can never fail a token (K4).
  ///
  /// Order of operations:
  /// 1. `trim()` each entry (leading/trailing whitespace is invisible in the UI
  ///    and would make two visually identical tags distinct);
  /// 2. drop entries that are empty after trimming;
  /// 3. clip to [maxTagRunes] runes;
  /// 4. drop exact duplicates, FIRST occurrence wins (so the user's own order
  ///    survives a rename that collides with an existing tag);
  /// 5. keep the first [maxTags].
  ///
  /// R12: clipping happens BEFORE the uniqueness check on purpose — two long
  /// import group names that share their first 32 runes MERGE into one tag
  /// instead of leaving the account with two identical labels.
  ///
  /// R9: matching is exact string equality, NOT case- or locale-folded. Turkish
  /// dotted/dotless İ/i pairs ("İş" vs "iş") therefore stay distinct tags; only
  /// the chip-strip ORDERING is case-insensitive (`VaultCubit.allTags`).
  ///
  /// The result is unmodifiable: it is handed straight to the [tags] field.
  static List<String> normalizeTags(Iterable<String> raw) {
    final out = <String>[];
    final seen = <String>{};
    for (final entry in raw) {
      final trimmed = entry.trim();
      if (trimmed.isEmpty) continue;
      final runes = trimmed.runes.toList(growable: false);
      final clipped = runes.length <= maxTagRunes
          ? trimmed
          : String.fromCharCodes(runes.take(maxTagRunes));
      if (!seen.add(clipped)) continue; // duplicate → first one wins
      out.add(clipped);
      if (out.length == maxTags) break;
    }
    return List<String>.unmodifiable(out);
  }

  /// Base32 secret'ın decode edilmiş byte hali.
  Uint8List get secretBytes => Base32.decode(secret);

  /// Lokal kalıcılık (flutter_secure_storage) için JSON gösterimi.
  ///
  /// NOT: Bu, `otpauth://` URI **değildir** — `id` ve `counter` gibi yerel/operasyonel
  /// alanları da taşır (URI bunları taşımaz). Faz 2'de bu JSON `masterKey` ile
  /// şifrelenerek saklanacak; şu an OS koruması (Keychain/Keystore) altında düz tutulur.
  Map<String, dynamic> toJson() => {
    'id': id,
    'secret': secret,
    'type': type.name,
    if (issuer != null) 'issuer': issuer,
    'accountName': accountName,
    'algorithm': algorithm.name,
    'digits': digits,
    'period': period,
    'counter': counter,
    // K2: written ONLY when non-empty. An untagged account keeps producing
    // the exact same JSON as before Patch 3, so upgrading a vault does not
    // re-encrypt (and re-push) every record. Unknown to older clients →
    // ignored on read, never a parse failure.
    if (tags.isNotEmpty) 'tags': tags,
  };

  /// [toJson] çıktısından geri kurar. Bilinmeyen/eksik/YANLIŞ TİPLİ alan →
  /// [FormatException] (bozuk depodan sessizce yanlış token üretmemek için).
  ///
  /// `as String?` / `as num?` cast'leri YERİNE tip-toleranslı yardımcılar
  /// kullanılır: `type: 123` veya `digits: "6"` gibi bozuk depo verisi
  /// `TypeError` (yakalanamaz) yerine `FormatException` üretir → çağıran
  /// (`VaultRepository.load`) tek bozuk kaydı güvenle atlayabilir.
  factory OtpAccount.fromJson(Map<String, dynamic> json) {
    final typeName = _asString(json['type'], 'type');
    final type = OtpType.values.where((t) => t.name == typeName).firstOrNull;
    if (type == null) {
      throw FormatException(
        'OtpAccount.fromJson: geçersiz "type": "$typeName"',
      );
    }
    final secret = _asString(json['secret'], 'secret');
    if (secret == null || secret.isEmpty) {
      throw const FormatException('OtpAccount.fromJson: "secret" zorunlu');
    }
    final accountName = _asString(json['accountName'], 'accountName');
    if (accountName == null) {
      throw const FormatException('OtpAccount.fromJson: "accountName" zorunlu');
    }
    return OtpAccount(
      id: _asString(json['id'], 'id'), // null ise yeni id üretilir
      secret: secret,
      type: type,
      issuer: _asString(json['issuer'], 'issuer'),
      accountName: accountName,
      algorithm: OtpAlgorithm.fromName(
        _asString(json['algorithm'], 'algorithm'),
      ),
      digits: _asInt(json['digits'], 'digits') ?? 6,
      period: _asInt(json['period'], 'period') ?? 30,
      counter: _asInt(json['counter'], 'counter') ?? 0,
      tags: _asTags(json['tags']),
    );
  }

  /// null → null; String → kendisi; aksi tip → [FormatException].
  static String? _asString(Object? v, String name) {
    if (v == null) return null;
    if (v is String) return v;
    throw FormatException(
      'OtpAccount.fromJson: "$name" String olmalı (verilen ${v.runtimeType})',
    );
  }

  /// Missing/null → `const []`; a `List` of `String` → itself; anything else →
  /// [FormatException].
  ///
  /// Only the TYPE is strict here. Content is normalized by the constructor and
  /// never rejected (K4) — a stored tag that is blank, over-long or duplicated
  /// is a normalization job, not a corrupt record. A `tags: "work"` or a
  /// `tags: [1, 2]` on the other hand means the blob is not what we wrote, and
  /// `VaultRepository.load` must be able to quarantine that single record
  /// instead of silently loading a half-understood token.
  static List<String> _asTags(Object? v) {
    if (v == null) return const [];
    if (v is! List) {
      throw FormatException(
        'OtpAccount.fromJson: "tags" liste olmalı (verilen ${v.runtimeType})',
      );
    }
    final out = <String>[];
    for (final e in v) {
      if (e is! String) {
        throw FormatException(
          'OtpAccount.fromJson: "tags" elemanları String olmalı '
          '(verilen ${e.runtimeType})',
        );
      }
      out.add(e);
    }
    return out;
  }

  /// null → null; int → itself; integer-valued double (e.g. 3.0) → int;
  /// numeric String → int; fractional num (e.g. 6.9) or any other type →
  /// [FormatException]. Fractional values are NOT silently truncated — this
  /// matches the strict policy used for KeyAttributes (see CRYPTO.md §8): a
  /// malformed `digits: 6.9` / `counter: 1.5` is rejected, not coerced to 6/1.
  static int? _asInt(Object? v, String name) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) {
      if (v == v.truncateToDouble()) return v.toInt(); // integer-valued double
      throw FormatException(
        'OtpAccount.fromJson: "$name" tam sayı olmalı (kesirli: $v)',
      );
    }
    if (v is String) {
      final parsed = int.tryParse(v);
      if (parsed != null) return parsed;
    }
    throw FormatException(
      'OtpAccount.fromJson: "$name" sayı olmalı (verilen ${v.runtimeType})',
    );
  }

  /// UI'da gösterilecek etiket: "Issuer (account)" veya yalnız account.
  String get label => (issuer != null && issuer!.isNotEmpty)
      ? '$issuer ($accountName)'
      : accountName;

  /// [id] varsayılan olarak KORUNUR (aynı token'ın güncellenmiş hali). Klonun
  /// yeni kimlik alması gerekiyorsa açıkça `id:` geçilmeli.
  OtpAccount copyWith({
    String? id,
    String? secret,
    OtpType? type,
    String? issuer,
    String? accountName,
    OtpAlgorithm? algorithm,
    int? digits,
    int? period,
    int? counter,
    List<String>? tags,
  }) {
    return OtpAccount(
      id: id ?? this.id,
      secret: secret ?? this.secret,
      type: type ?? this.type,
      issuer: issuer ?? this.issuer,
      accountName: accountName ?? this.accountName,
      algorithm: algorithm ?? this.algorithm,
      digits: digits ?? this.digits,
      period: period ?? this.period,
      counter: counter ?? this.counter,
      // Passing `const []` CLEARS the tags (the constructor normalizes it to an
      // empty list). There is no separate `clearTags` flag: an empty list is
      // already the "no tags" value, so the null-means-keep rule is enough.
      tags: tags ?? this.tags,
    );
  }

  @override
  List<Object?> get props => [
    id,
    secret,
    type,
    issuer,
    accountName,
    algorithm,
    digits,
    period,
    counter,
    // K3 — MANDATORY (risk R2). `EncryptedVaultRepository._writeRecords`
    // keeps the previous ciphertext when `prev.account == account`
    // (encrypted_vault_repository.dart:219). Omitting [tags] here would make
    // a tags-only edit compare equal, so the new tags would never be
    // encrypted, never reach the store and never sync — and nothing would
    // report an error.
    tags,
  ];

  /// SECURITY: Equatable's `stringify` defaults to ON in debug builds, which
  /// would make `toString()` print every prop — [secret] included. Any debug
  /// `print`, a widget-tree dump, an assertion message or a CI test failure that
  /// interpolates an account would then leak the TOTP seed into a log. Keep the
  /// terse `OtpAccount` form instead; call sites that need detail can name the
  /// non-secret fields explicitly.
  @override
  bool get stringify => false;
}
