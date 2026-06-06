/// Tek bir OTP hesabını gösteren kart: kod + geri sayım + kopyalama.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/di/locator.dart';
import '../../../../core/otp/otp_account.dart';
import '../../../../core/otp/otp_generator.dart';

class OtpCard extends StatefulWidget {
  final OtpAccount account;
  final VoidCallback? onIncrement; // HOTP için
  final VoidCallback? onDelete;

  const OtpCard({
    super.key,
    required this.account,
    this.onIncrement,
    this.onDelete,
  });

  @override
  State<OtpCard> createState() => _OtpCardState();
}

class _OtpCardState extends State<OtpCard> {
  final OtpGenerator _gen = locator<OtpGenerator>();
  Timer? _timer;
  String _code = '';
  int _remaining = 0;

  bool get _isTimeBased => widget.account.type != OtpType.hotp;

  @override
  void initState() {
    super.initState();
    _recompute();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant OtpCard old) {
    super.didUpdateWidget(old);
    if (old.account != widget.account) {
      _recompute();
      // Tip değişebilir (TOTP↔HOTP, örn. düzenleme veya State reuse): timer'ı
      // güncel tipe göre başlat/iptal et — aksi halde TOTP kartı donar veya
      // HOTP kartında gereksiz timer döner.
      _syncTimer();
    }
  }

  /// Zamana bağlı tipte (TOTP/Steam) saniyelik timer çalışmalı; HOTP'te çalışmamalı.
  /// Mevcut durum hedefle uyumluysa dokunmaz (idempotent).
  void _syncTimer() {
    if (_isTimeBased) {
      _timer ??=
          Timer.periodic(const Duration(seconds: 1), (_) => _recompute());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _recompute() {
    final a = widget.account;
    final now = DateTime.now();
    String code;
    switch (a.type) {
      case OtpType.totp:
        code = _gen.totp(
          secret: a.secretBytes,
          time: now,
          period: a.period,
          digits: a.digits,
          algorithm: a.algorithm,
        );
      case OtpType.steam:
        code = _gen.steam(secret: a.secretBytes, time: now, period: a.period);
      case OtpType.hotp:
        code = _gen.hotp(
          secret: a.secretBytes,
          counter: a.counter,
          digits: a.digits,
          algorithm: a.algorithm,
        );
    }
    if (!mounted) return;
    setState(() {
      _code = code;
      _remaining = _isTimeBased
          ? _gen.secondsRemaining(time: now, period: a.period)
          : 0;
    });
  }

  String get _formattedCode {
    // 6 haneyi "123 456" gibi gruplar (Steam/8 hane için ham gösterim).
    if (_code.length == 6) return '${_code.substring(0, 3)} ${_code.substring(3)}';
    return _code;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        title: Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          _formattedCode,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
            letterSpacing: 2,
            color: theme.colorScheme.primary,
          ),
        ),
        leading: _isTimeBased
            ? _Countdown(remaining: _remaining, period: a.period)
            : IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Sonraki kod',
                onPressed: widget.onIncrement,
              ),
        trailing: IconButton(
          icon: const Icon(Icons.copy),
          tooltip: 'Kopyala',
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: _code));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Kod kopyalandı')),
            );
          },
        ),
        onLongPress: widget.onDelete,
      ),
    );
  }
}

class _Countdown extends StatelessWidget {
  final int remaining;
  final int period;
  const _Countdown({required this.remaining, required this.period});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: period == 0 ? 0 : remaining / period,
            strokeWidth: 3,
          ),
          Text('$remaining', style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}
