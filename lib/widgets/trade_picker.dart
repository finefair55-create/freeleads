import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/search_profile.dart';
import '../models/trade.dart';
import '../theme/app_theme.dart';
import 'motion.dart';

/// The active trade as one compact "Trade: Plumbing ▾" button, first in the
/// feed's filter bar. It opens a sheet listing the common trades (plus the user's
/// own when it isn't one of them); picking one saves it to the profile and
/// searches for it right away.
class TradePicker extends StatelessWidget {
  const TradePicker({
    super.key,
    this.onOther,
    this.padding = Spacing.md,
    this.inline = false,
  });

  /// Opens the full trade picker, for trades not offered here.
  final VoidCallback? onOther;

  /// Horizontal inset, matching the feed's gutter.
  final double padding;

  /// Just the button, sized to fit, e.g. as the first item in a chip row;
  /// [padding] is ignored.
  final bool inline;

  /// Returned by the sheet for "Other trade…".
  static const _other = Trade('Other', '', Icons.edit_outlined);

  Future<void> _switch(BuildContext context, Trade trade) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await AppScope.of(context).repository.switchTrade(trade.query);
    } catch (error) {
      debugPrint('Switching trade failed: $error');
      messenger?.showSnackBar(
        const SnackBar(content: Text("Couldn't switch trades. Try again.")),
      );
    }
  }

  Future<void> _open(BuildContext context, String activeLabel) async {
    final choice = await showModalBottomSheet<Trade>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _TradeSheet(
        activeLabel: activeLabel,
        other: onOther == null ? null : _other,
      ),
    );
    if (choice == null || !context.mounted) {
      return;
    }
    if (identical(choice, _other)) {
      onOther?.call();
    } else if (choice.label != activeLabel) {
      await _switch(context, choice);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = AppScope.of(context).repository;
    return ValueListenableBuilder<SearchProfile?>(
      valueListenable: repository.profile,
      builder: (context, profile, _) {
        if (profile == null) {
          return const SizedBox.shrink();
        }
        final active = Trade.match(profile.profession);
        final label = active?.label ?? Trade.displayName(profile.profession);
        final button = _PickerButton(
          label: label,
          icon: active?.icon ?? Icons.work_outline,
          onTap: () => _open(context, label),
        );
        if (inline) {
          return button;
        }
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: padding),
          child: Align(alignment: Alignment.centerLeft, child: button),
        );
      },
    );
  }
}

/// "[icon] Trade: Plumbing ▾" in a card-colored pill.
class _PickerButton extends StatelessWidget {
  const _PickerButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textStyle = theme.textTheme.labelLarge;
    final radius = BorderRadius.circular(AppTheme.radiusChip);
    return Semantics(
      button: true,
      label: 'Trade: $label. Change trade',
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        scale: 0.97,
        borderRadius: AppTheme.radiusChip,
        child: Material(
          color: theme.cardTheme.color ?? scheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(
              color: theme.dividerTheme.color ?? scheme.outlineVariant,
            ),
          ),
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: scheme.primary),
                  const SizedBox(width: Spacing.xs),
                  Flexible(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: 'Trade: ',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          TextSpan(
                            text: label,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textStyle,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.expand_more, size: 20, color: scheme.onSurface),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The trade list in the bottom sheet; pops with the picked [Trade].
class _TradeSheet extends StatelessWidget {
  const _TradeSheet({required this.activeLabel, this.other});

  final String activeLabel;

  /// Shown last as "Other trade…" when the feed can open the full picker.
  final Trade? other;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final custom = Trade.common.any((trade) => trade.label == activeLabel)
        ? null
        : Trade(activeLabel, '', Icons.work_outline);
    Widget tile(Trade trade, {String? title}) {
      final selected = trade.label == activeLabel;
      return ListTile(
        leading: Icon(
          trade.icon,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        ),
        title: Text(
          title ?? trade.label,
          style: selected
              ? TextStyle(color: scheme.primary, fontWeight: FontWeight.w700)
              : null,
        ),
        trailing: selected ? Icon(Icons.check, color: scheme.primary) : null,
        selected: selected,
        onTap: () => Navigator.pop(context, trade),
      );
    }

    final other = this.other;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.75,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              0,
              Spacing.lg,
              Spacing.xs,
            ),
            child: Text(
              'Choose your trade',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              0,
              Spacing.lg,
              Spacing.sm,
            ),
            child: Text(
              'Your feed searches for this trade right away.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: Spacing.md),
              children: [
                if (custom != null) tile(custom),
                for (final trade in Trade.common) tile(trade),
                if (other != null) ...[
                  const Divider(height: Spacing.md),
                  tile(other, title: 'Other trade…'),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
