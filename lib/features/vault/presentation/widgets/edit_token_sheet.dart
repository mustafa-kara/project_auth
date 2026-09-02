/// Kod düzenleme sheet'i — servis / hesap adı / etiketler.
///
/// Phase 5 Patch 3 (plan §5 D2).
///
/// SECURITY: this screen NEVER shows, reads or copies the token secret. It does
/// not touch `account.secret` at all, and [VaultCubit.editMetadata] does not
/// even accept a secret (nor type/algorithm/digits/period/counter): an edit
/// screen that could rewrite the seed or the code geometry would let one typo
/// silently produce wrong codes forever, with no way back for the user. Only
/// non-secret metadata is editable here, which is also why the form can be
/// rendered next to a live code without weakening anything.
library;

import 'package:flutter/material.dart';

import '../../../../core/otp/otp_account.dart';
import '../../../../core/ui/tokens.dart';
import '../../../../core/ui/widgets/app_text_field.dart';
import '../../../../core/ui/widgets/auth_bits.dart';
import '../bloc/vault_cubit.dart';

class EditTokenSheet extends StatefulWidget {
  final OtpAccount account;
  final VaultCubit cubit;

  /// Opened from "Etiketleri düzenle" → the tag input takes focus so the user
  /// lands on the field they asked for instead of the issuer field.
  final bool focusTags;

  const EditTokenSheet({
    super.key,
    required this.account,
    required this.cubit,
    this.focusTags = false,
  });

  @override
  State<EditTokenSheet> createState() => _EditTokenSheetState();
}

class _EditTokenSheetState extends State<EditTokenSheet> {
  late final TextEditingController _issuer =
      TextEditingController(text: widget.account.issuer ?? '');
  late final TextEditingController _accountName =
      TextEditingController(text: widget.account.accountName);
  final TextEditingController _tagInput = TextEditingController();

  /// Working copy of the tags, kept normalized at every step so the UI shows
  /// exactly what would be persisted (no surprise trimming on save).
  late List<String> _tags = List<String>.of(widget.account.tags);

  String? _error;
  bool _saving = false;

  bool get _atCap => _tags.length >= OtpAccount.maxTags;

  /// An empty account name would leave the card with a blank label, so saving
  /// is blocked rather than silently producing an unidentifiable token.
  bool get _nameMissing => _accountName.text.trim().isEmpty;

  @override
  void initState() {
    super.initState();
    // "Kaydet" is gated on the account name, so the gate has to follow typing —
    // the text field rebuilds itself, the sheet around it does not.
    _accountName.addListener(_onNameChanged);
  }

  void _onNameChanged() => setState(() {});

  @override
  void dispose() {
    _accountName.removeListener(_onNameChanged);
    _issuer.dispose();
    _accountName.dispose();
    _tagInput.dispose();
    super.dispose();
  }

  void _addTag(String raw) {
    if (raw.trim().isEmpty) return;
    // The model owns the rules (trim, dedupe, 32-rune clip, 8 cap) — the sheet
    // never re-implements them, so what is shown is what is stored.
    final next = OtpAccount.normalizeTags([..._tags, raw]);
    setState(() {
      _tags = next;
      _tagInput.clear();
    });
  }

  void _removeTag(String tag) {
    setState(() {
      _tags = OtpAccount.normalizeTags(_tags.where((t) => t != tag));
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.cubit.editMetadata(
        id: widget.account.id,
        issuer: _issuer.text.trim(),
        accountName: _accountName.text.trim(),
        tags: _tags,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      // Keep the form open on a write failure: closing it would look like the
      // edit landed while the vault still holds the old values.
      if (mounted) setState(() => _error = 'Kaydedilemedi: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Tags already on the token are not offered again.
    final suggestions =
        widget.cubit.allTags.where((t) => !_tags.contains(t)).toList();

    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.sm,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Kodu düzenle', style: theme.textTheme.titleMedium),
            const SizedBox(height: Gap.md),
            AppTextField(
              controller: _issuer,
              label: 'Servis',
              autofocus: !widget.focusTags,
            ),
            const SizedBox(height: Gap.md),
            AppTextField(
              controller: _accountName,
              label: 'Hesap',
              errorText: _nameMissing ? 'Hesap adı boş olamaz.' : null,
            ),
            const SizedBox(height: Gap.lg),
            _tagField(theme),
            if (_tags.isNotEmpty) ...[
              const SizedBox(height: Gap.sm),
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.xs,
                children: [
                  for (final tag in _tags)
                    InputChip(
                      label: Text(tag),
                      onDeleted: _saving ? null : () => _removeTag(tag),
                      deleteButtonTooltipMessage: 'Etiketi kaldır',
                    ),
                ],
              ),
            ],
            if (suggestions.isNotEmpty && !_atCap) ...[
              const SizedBox(height: Gap.md),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Öneriler',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: Gap.xs),
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.xs,
                children: [
                  for (final tag in suggestions)
                    ActionChip(
                      label: Text(tag),
                      onPressed: _saving ? null : () => _addTag(tag),
                    ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: Gap.md),
              AuthErrorText(_error!),
            ],
            const SizedBox(height: Gap.lg),
            FilledButton(
              onPressed: (_saving || _nameMissing) ? null : _save,
              child: _saving ? const BtnSpinner() : const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
  }

  /// Tag entry. A raw [TextField] rather than `AppTextField` because this one
  /// needs `maxLength` (the model's 32-rune ceiling, surfaced BEFORE the value
  /// is silently clipped) and an `enabled` flag for the 8-tag cap; it still
  /// inherits the shared `inputDecorationTheme`.
  Widget _tagField(ThemeData theme) => TextField(
        controller: _tagInput,
        enabled: !_atCap && !_saving,
        autofocus: widget.focusTags,
        maxLength: OtpAccount.maxTagRunes,
        textInputAction: TextInputAction.done,
        onSubmitted: _addTag,
        decoration: InputDecoration(
          labelText: 'Etiket',
          hintText: 'Etiket ekle (en fazla ${OtpAccount.maxTags})',
          helperText: _atCap
              ? 'En fazla ${OtpAccount.maxTags} etiket ekleyebilirsin.'
              : null,
          helperStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          suffixIcon: IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Etiketi ekle',
            onPressed:
                _atCap || _saving ? null : () => _addTag(_tagInput.text),
          ),
        ),
      );
}
