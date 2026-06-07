/// Standart metin alanı (Design.md §4): görünür label (placeholder-only DEĞİL),
/// inline hata, parola için show/hide. Tema `inputDecorationTheme`'i miras alır
/// (filled + Radii.md border) — ekranlar ham `TextField` yerine bunu kullanır.
library;

import 'package:flutter/material.dart';

class AppTextField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;

  /// Sabit yardımcı metin (label altında; Design.md input-helper-text).
  final String? helperText;

  /// Inline hata (label altında, error renginde). null = hata yok.
  final String? errorText;

  /// Parola alanı mı (show/hide toggle + başlangıçta gizli).
  final bool obscure;

  /// Çok satırlı (recovery mnemonic gibi). null = tek satır.
  final int? minLines;
  final int? maxLines;

  final TextInputType? keyboardType;
  final bool autocorrect;
  final bool enableSuggestions;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final FormFieldValidator<String>? validator;

  const AppTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.helperText,
    this.errorText,
    this.obscure = false,
    this.minLines,
    this.maxLines,
    this.keyboardType,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.autofocus = false,
    this.onSubmitted,
    this.validator,
  });

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late bool _obscured = widget.obscure;

  @override
  Widget build(BuildContext context) {
    final showToggle = widget.obscure;
    return TextFormField(
      controller: widget.controller,
      obscureText: _obscured,
      autocorrect: widget.autocorrect,
      enableSuggestions: widget.enableSuggestions,
      autofocus: widget.autofocus,
      keyboardType: widget.keyboardType,
      minLines: widget.obscure ? 1 : widget.minLines,
      maxLines: _obscured ? 1 : (widget.maxLines ?? 1),
      onFieldSubmitted: widget.onSubmitted,
      validator: widget.validator,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        helperText: widget.helperText,
        errorText: widget.errorText,
        suffixIcon: showToggle
            ? IconButton(
                icon: Icon(
                    _obscured ? Icons.visibility : Icons.visibility_off),
                tooltip: _obscured ? 'Göster' : 'Gizle',
                onPressed: () => setState(() => _obscured = !_obscured),
              )
            : null,
      ),
    );
  }
}
