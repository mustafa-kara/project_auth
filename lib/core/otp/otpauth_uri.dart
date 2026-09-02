/// `otpauth://` URI parse/serialize (Key URI Format).
///
/// Format: otpauth://TYPE/LABEL?secret=...&issuer=...&algorithm=...&digits=...&period=...&counter=...
/// LABEL = "issuer:account" veya "account". Steam için TYPE=totp + issuer=Steam
/// (yaygın convention) veya bazı uygulamalarda otpauth://steam/...
library;

import 'dart:typed_data';

import 'base32.dart';
import 'otp_account.dart';
import 'otp_algorithm.dart';

class OtpAuthUri {
  const OtpAuthUri._();

  /// `otpauth://` string'ini [OtpAccount]'a çevirir.
  /// Geçersiz şema/eksik secret durumunda [FormatException] fırlatır.
  static OtpAccount parse(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null || uri.scheme.toLowerCase() != 'otpauth') {
      throw const FormatException('Geçersiz otpauth URI: şema "otpauth" olmalı');
    }

    final host = uri.host.toLowerCase();
    final OtpType type = switch (host) {
      'totp' => OtpType.totp,
      'hotp' => OtpType.hotp,
      'steam' => OtpType.steam,
      _ => throw FormatException('Bilinmeyen otpauth tipi: "$host"'),
    };

    // LABEL: path'in baş "/" sonrası, URL-decode edilmiş "issuer:account".
    final rawLabel =
        uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
    final label = Uri.decodeComponent(rawLabel);
    String? labelIssuer;
    String accountName = label;
    final colon = label.indexOf(':');
    if (colon >= 0) {
      labelIssuer = label.substring(0, colon).trim();
      accountName = label.substring(colon + 1).trim();
    }

    final q = uri.queryParameters;
    final secret = q['secret'];
    if (secret == null || secret.isEmpty) {
      throw const FormatException('otpauth URI: "secret" parametresi zorunlu');
    }
    // Secret PARSE ANINDA doğrulanır — geç (kart render'ında) FormatException'la
    // UI'ı çökertmek yerine, geçersiz girişi burada reddet. Boş byte = geçersiz secret.
    final Uint8List secretBytes;
    try {
      secretBytes = Base32.decode(secret);
    } on FormatException {
      throw const FormatException('otpauth URI: "secret" geçerli Base32 değil');
    }
    if (secretBytes.isEmpty) {
      throw const FormatException('otpauth URI: "secret" boş/çözülemedi');
    }

    // issuer parametresi label'daki issuer'ı geçersiz kılar (spec önceliği query'de).
    final issuer = (q['issuer']?.isNotEmpty ?? false) ? q['issuer'] : labelIssuer;

    // Steam: host=steam ise SHA1/period=30 sabit; digits Steam kodlamasında kullanılmaz.
    //
    // `issuer == "steam"` sezgisi projede kalan TEK issuer tabanlı Steam
    // çıkarımıdır ve BİLİNÇLİ (denetim B1): `otpauth://` şemasında Steam'in
    // kendi host'u YOKTUR — Steam Guard bağlantıları konvansiyon gereği
    // `otpauth://totp/Steam:<hesap>?issuer=Steam` diye kodlanır, yani issuer
    // burada gerçekten tipin taşıyıcısıdır. Aegis/2FAS/Google yollarında aynı
    // sezgi KALDIRILDI, çünkü o formatların birinci sınıf bir Steam tipi var
    // (`type:"steam"`, `tokenType:"STEAM"`) → orada issuer'a bakmak, kullanıcının
    // yalnızca "Steam" diye ADLANDIRDIĞI sıradan bir TOTP'yi bozar.
    final isSteam = type == OtpType.steam ||
        (issuer?.toLowerCase() == 'steam' && host == 'totp');

    // Sayısal parametreler MAKUL ARALIKTA olmalı (yoksa kod üretiminde bölme hatası /
    // anlamsız çıktı). Eksik → güvenli varsayılan; verilmiş ama geçersiz → reddet.
    final digits = _parseBounded(q['digits'], 'digits',
        fallback: isSteam ? 5 : 6, min: 6, max: 8, allow: isSteam ? const [5] : null);
    final period = _parseBounded(q['period'], 'period', fallback: 30, min: 1, max: 600);
    // HOTP'te `counter` Key URI Format'a göre ZORUNLUDUR (hareketli operasyonel
    // state). Eksik counter'ı 0 varsaymak yanlış sayaçla token ekletir → reddet.
    // TOTP/Steam için counter kullanılmaz; eksikse 0 varsayılır.
    final bool counterRequired = (isSteam ? OtpType.steam : type) == OtpType.hotp;
    final counter = _parseBounded(q['counter'], 'counter',
        fallback: 0, min: 0, required: counterRequired);

    return OtpAccount(
      secret: secret,
      type: isSteam ? OtpType.steam : type,
      issuer: issuer,
      accountName: accountName,
      algorithm: OtpAlgorithm.fromName(q['algorithm']),
      digits: digits,
      period: period,
      counter: counter,
    );
  }

  /// Sayısal query parametresini parse eder + aralık doğrular.
  /// [raw] null/boş → [required] ise [FormatException], değilse [fallback].
  /// Sayı değilse veya [min]/[max] dışındaysa (ve [allow] listesinde değilse)
  /// [FormatException]. [max] null = üst sınır yok.
  static int _parseBounded(
    String? raw,
    String name, {
    required int fallback,
    required int min,
    int? max,
    List<int>? allow,
    bool required = false,
  }) {
    if (raw == null || raw.isEmpty) {
      if (required) {
        throw FormatException('otpauth URI: "$name" zorunlu (eksik)');
      }
      return fallback;
    }
    final v = int.tryParse(raw);
    if (v == null) {
      throw FormatException('otpauth URI: "$name" sayı değil: "$raw"');
    }
    if (allow != null && allow.contains(v)) return v;
    if (v < min || (max != null && v > max)) {
      throw FormatException(
          'otpauth URI: "$name" aralık dışı ($v); beklenen $min..${max ?? '∞'}');
    }
    return v;
  }

  /// [OtpAccount]'u kanonik `otpauth://` string'ine çevirir.
  static String serialize(OtpAccount account) {
    final typeHost = switch (account.type) {
      OtpType.totp => 'totp',
      OtpType.hotp => 'hotp',
      OtpType.steam => 'steam',
    };

    final labelParts = <String>[];
    if (account.issuer != null && account.issuer!.isNotEmpty) {
      labelParts.add(account.issuer!);
    }
    labelParts.add(account.accountName);
    final label = labelParts.join(':');

    final params = <String, String>{
      'secret': account.secret,
      if (account.issuer != null && account.issuer!.isNotEmpty)
        'issuer': account.issuer!,
      'algorithm': account.algorithm.uriName,
      'digits': account.digits.toString(),
    };
    if (account.type == OtpType.hotp) {
      params['counter'] = account.counter.toString();
    } else {
      params['period'] = account.period.toString();
    }

    final query = params.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');

    return 'otpauth://$typeHost/${Uri.encodeComponent(label)}?$query';
  }
}
