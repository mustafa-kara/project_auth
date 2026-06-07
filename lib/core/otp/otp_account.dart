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
  }) : id = id ?? _uuid.v4() {
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
        throw FormatException('OtpAccount: Steam "digits" 5 olmalı (verilen $digits)');
      }
    } else if (digits < 6 || digits > 8) {
      throw FormatException('OtpAccount: "digits" 6..8 olmalı (verilen $digits)');
    }
    // period: TOTP/Steam için >0 (secondsRemaining/totp bölme yapar). HOTP'te
    // kullanılmaz ama yine de anlamsız negatifi reddet.
    if (period < 1 || period > 600) {
      throw FormatException('OtpAccount: "period" 1..600 olmalı (verilen $period)');
    }
    // counter: negatif olamaz.
    if (counter < 0) {
      throw FormatException('OtpAccount: "counter" negatif olamaz (verilen $counter)');
    }
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
      throw FormatException('OtpAccount.fromJson: geçersiz "type": "$typeName"');
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
      algorithm: OtpAlgorithm.fromName(_asString(json['algorithm'], 'algorithm')),
      digits: _asInt(json['digits'], 'digits') ?? 6,
      period: _asInt(json['period'], 'period') ?? 30,
      counter: _asInt(json['counter'], 'counter') ?? 0,
    );
  }

  /// null → null; String → kendisi; aksi tip → [FormatException].
  static String? _asString(Object? v, String name) {
    if (v == null) return null;
    if (v is String) return v;
    throw FormatException('OtpAccount.fromJson: "$name" String olmalı (verilen ${v.runtimeType})');
  }

  /// null → null; num → int; sayısal String → int; aksi → [FormatException].
  static int? _asInt(Object? v, String name) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    if (v is String) {
      final parsed = int.tryParse(v);
      if (parsed != null) return parsed;
    }
    throw FormatException('OtpAccount.fromJson: "$name" sayı olmalı (verilen ${v.runtimeType})');
  }

  /// UI'da gösterilecek etiket: "Issuer (account)" veya yalnız account.
  String get label =>
      (issuer != null && issuer!.isNotEmpty) ? '$issuer ($accountName)' : accountName;

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
    );
  }

  @override
  List<Object?> get props =>
      [id, secret, type, issuer, accountName, algorithm, digits, period, counter];
}
