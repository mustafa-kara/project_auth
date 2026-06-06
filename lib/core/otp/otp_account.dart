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
  }) : id = id ?? _uuid.v4();

  /// Base32 secret'ın decode edilmiş byte hali.
  Uint8List get secretBytes => Base32.decode(secret);

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
