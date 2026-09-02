/// Etiket filtre şeridi — arama alanının hemen altında yatay kaydırmalı çipler.
///
/// Phase 5 Patch 3 (plan §5 D1). Single selection, session-scoped: the filter is
/// deliberately NOT persisted, so re-opening the vault always shows every code —
/// a filter that survives a restart is the classic way a user concludes their
/// token is gone.
///
/// Renders NOTHING when the vault carries no tags: an empty strip would take a
/// row of vertical space away from the codes for no benefit.
///
/// a11y: the strip is one labelled container ("Etiket filtresi") with explicit
/// child nodes, each chip exposes `button` + `selected`, and selection is
/// signalled by a check icon as well as colour (colour is never the only
/// signal, Design.md §5).
library;

import 'package:flutter/material.dart';

import '../../../../core/ui/tokens.dart';

class TagChipsBar extends StatelessWidget {
  /// Tags to offer, already ordered by the cubit (`VaultCubit.allTags`:
  /// most-used first). The strip does not re-sort them.
  final List<String> tags;

  /// Currently filtered tag, or null for "no filter".
  final String? selected;

  /// Called with the new selection; null means the filter was cleared (tapping
  /// the selected chip again toggles it off).
  final ValueChanged<String?> onSelected;

  /// Opens the tag manager (rename / delete), the last chip in the strip.
  final VoidCallback onManage;

  /// Minimum touch target for every chip (Design.md §5 — 48dp).
  static const double minTouchTarget = 48;

  /// Strip height: touch target + breathing room above/below.
  static const double stripHeight = minTouchTarget + Gap.sm * 2;

  const TagChipsBar({
    super.key,
    required this.tags,
    required this.selected,
    required this.onSelected,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Etiket filtresi',
      child: SizedBox(
        height: stripHeight,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          itemCount: tags.length + 1,
          separatorBuilder: (context, index) => const SizedBox(width: Gap.sm),
          itemBuilder: (context, i) {
            if (i == tags.length) {
              return Center(
                child: _ChipTarget(
                  label: 'Etiketleri yönet',
                  onTap: onManage,
                  child: ActionChip(
                    avatar: const Icon(Icons.settings_outlined, size: 18),
                    label: const Text('Etiketleri yönet'),
                    onPressed: onManage,
                  ),
                ),
              );
            }
            final tag = tags[i];
            final isSelected = tag == selected;
            return Center(
              child: _ChipTarget(
                label: tag,
                selected: isSelected,
                // Tapping the active chip clears the filter (toggle).
                onTap: () => onSelected(isSelected ? null : tag),
                child: FilterChip(
                  selected: isSelected,
                  // Own check avatar instead of the built-in checkmark so the
                  // "selected" state is an ICON, not just a fill colour.
                  showCheckmark: false,
                  avatar: isSelected ? const Icon(Icons.check, size: 18) : null,
                  label: Text(tag),
                  onSelected: (_) => onSelected(isSelected ? null : tag),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Wraps one chip so it reports a single, correct semantics node (button +
/// selected + label) and can never render below the 48dp touch target.
///
/// The Material chip's own semantics are excluded: merging them with the outer
/// node produced a duplicated label, and `selected` is what a screen reader
/// needs to announce the filter state.
class _ChipTarget extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  const _ChipTarget({
    required this.label,
    required this.onTap,
    required this.child,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: label,
        onTap: onTap,
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: TagChipsBar.minTouchTarget,
          ),
          child: child,
        ),
      );
}
