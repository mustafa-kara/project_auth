/// Tek bir OTP hesabını gösteren kart (Design.md §4): kod + geri sayım + logo.
///
/// İki varyant: spacious kart (varsayılan) ↔ kompakt liste. Kod hep görünür;
/// karta/koda tek tap = panoya kopyala + kısa onay (tap-to-reveal YOK). Kod
/// GeistMono + tabular; sayaç [CountdownRing]; logo [IssuerAvatar]. Semantics ile
/// kod + kalan süre tek etikette duyurulur.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../../../core/di/locator.dart';
import '../../../../core/otp/otp_account.dart';
import '../../../../core/otp/otp_generator.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/countdown_ring.dart';
import '../../../../core/ui/widgets/issuer_avatar.dart';

class OtpCard extends StatefulWidget {
  final OtpAccount account;
  final VoidCallback? onIncrement; // HOTP için
  final VoidCallback? onDelete;

  /// Phase 5 Patch 3 — long-press handler. Null → a long press does NOTHING.
  ///
  /// There is deliberately no fallback to [onDelete]: a long press used to
  /// remove a token outright, so a mis-touch while scrolling cost the user
  /// access to that account's 2FA (risk R10 — behaviour change, in the
  /// CHANGELOG). The vault passes the action sheet ("Kodu düzenle" /
  /// "Etiketleri düzenle" / "Sil") here, and every delete path is confirmed by
  /// the caller before [onDelete] is ever invoked.
  final VoidCallback? onLongPress;

  /// Phase 5 Patch 3 — opens the edit sheet for this token.
  ///
  /// Exposed as its own callback (not folded into [onLongPress]) because a
  /// screen-reader user cannot "long press": the action sheet is unreachable
  /// for them, so 'Düzenle' and 'Sil' are published as
  /// `customSemanticsActions` instead. Null → that action is not offered.
  final VoidCallback? onEdit;

  /// Kompakt liste görünümü mü (false = spacious kart).
  final bool compact;

  const OtpCard({
    super.key,
    required this.account,
    this.onIncrement,
    this.onDelete,
    this.onLongPress,
    this.onEdit,
    this.compact = false,
  });

  @override
  State<OtpCard> createState() => _OtpCardState();
}

class _OtpCardState extends State<OtpCard> {
  final OtpGenerator _gen = locator<OtpGenerator>();
  Timer? _timer;
  String _code = '';
  int _remaining = 0;

  /// The OTP code is sensitive → not left in the clipboard indefinitely: cleared
  /// conditionally ~[_clearAfter] after a copy. If the clipboard still holds the
  /// code we wrote, it is removed; if the user copied something else in the
  /// meantime it is LEFT UNTOUCHED (we don't overwrite their data). Short window:
  /// OTP rotates with its period and the user pastes immediately.
  /// (Same pattern as recovery_show_page — there 60s; OTP is shorter-lived.)
  static const Duration _clearAfter = Duration(seconds: 30);
  Timer? _clearTimer;
  String? _copiedValue;

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
      _syncTimer();
    }
  }

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
    if (_code.length == 6) {
      return '${_code.substring(0, 3)} ${_code.substring(3)}';
    }
    return _code;
  }

  Future<void> _copy() async {
    final code = _code;
    await Clipboard.setData(ClipboardData(text: code));
    _copiedValue = code;
    _clearTimer?.cancel();
    _clearTimer = Timer(_clearAfter, _clearClipboardIfUnchanged);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('Kod kopyalandı')));
  }

  /// Clear the clipboard only if it still holds the code we copied (leave it alone
  /// if the user copied something else in the meantime). Runs from the timer even
  /// if the widget has been disposed — it touches only instance fields + Clipboard
  /// (no context/setState), so it is safe after dispose.
  Future<void> _clearClipboardIfUnchanged() async {
    final copied = _copiedValue;
    if (copied == null) return;
    final current = await Clipboard.getData(Clipboard.kTextPlain);
    if (current?.text == copied) {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
    _copiedValue = null;
  }

  /// Erişilebilirlik etiketi: kod + (zamana bağlıysa) kalan süre.
  String get _semanticsLabel {
    final a = widget.account;
    final base = '${a.label}, kod $_code';
    return _isTimeBased ? '$base, $_remaining saniye kaldı' : base;
  }

  @override
  void dispose() {
    _timer?.cancel();
    // NOTE: _clearTimer is intentionally NOT cancelled here — the conditional
    // clipboard wipe must still fire after the card is disposed (e.g. scrolled
    // out of view). Its callback is disposed-safe (no context/setState).
    super.dispose();
  }

  Widget _trailing() => _isTimeBased
      ? CountdownRing(
          remaining: _remaining,
          period: widget.account.period,
          size: widget.compact ? 36 : 44,
        )
      : IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Sonraki kod',
          onPressed: widget.onIncrement,
        );

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    final codeStyle = widget.compact
        ? AppTheme.monoCodeCompact(context)
        : AppTheme.monoCode(context);
    final avatarSize = widget.compact ? 36.0 : 44.0;

    final content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: Gap.lg,
        vertical: widget.compact ? Gap.sm : Gap.md,
      ),
      child: Row(
        children: [
          IssuerAvatar(
            issuer: a.issuer,
            fallbackLabel: a.accountName,
            size: avatarSize,
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(a.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(height: Gap.xs),
                Text(_formattedCode, style: codeStyle),
              ],
            ),
          ),
          const SizedBox(width: Gap.md),
          _trailing(),
        ],
      ),
    );

    // 'Düzenle' / 'Sil' as assistive actions: the same operations the long-press
    // sheet offers, reachable without a long press (TalkBack/VoiceOver expose
    // them in the actions menu). The primary label and tap (copy the code) are
    // untouched — this only ADDS actions.
    final actions = <CustomSemanticsAction, VoidCallback>{
      if (widget.onEdit != null)
        const CustomSemanticsAction(label: 'Düzenle'): widget.onEdit!,
      if (widget.onDelete != null)
        const CustomSemanticsAction(label: 'Sil'): widget.onDelete!,
    };

    final tappable = Semantics(
      label: _semanticsLabel,
      button: true,
      onTap: _copy,
      customSemanticsActions: actions.isEmpty ? null : actions,
      child: InkWell(
        onTap: _copy, // tek tap = kopyala
        onLongPress: widget.onLongPress,
        borderRadius: BorderRadius.circular(Radii.lg),
        child: content,
      ),
    );

    // Her iki varyant da `surface` kart + hairline border (Design.md §14.1);
    // fark yoğunlukta (avatar/kod/padding), kart kimliğinde değil.
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Gap.md,
        widget.compact ? Gap.xs : Gap.sm,
        Gap.md,
        0,
      ),
      child: Card(child: tappable),
    );
  }
}
