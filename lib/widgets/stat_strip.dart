import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

typedef Stat = ({String label, String value, IconData icon});

/// A few key numbers in one slim row, split by hairlines, for the bottom of
/// the feed's control panel. Each reads "5 Open leads" on one line when
/// there's room, and stacks the label under the number on phones.
class StatStrip extends StatelessWidget {
  const StatStrip({super.key, required this.stats});

  final List<Stat> stats;

  /// From this width every stat fits on one line.
  static const _inlineWidth = 480.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final inline = constraints.maxWidth >= _inlineWidth;
        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: Spacing.xxs,
            vertical: inline ? Spacing.xs : 6,
          ),
          child: Row(
            children: [
              for (final (i, stat) in stats.indexed) ...[
                if (i > 0)
                  SizedBox(
                    height: inline ? 20 : 28,
                    child: const VerticalDivider(width: 1),
                  ),
                Expanded(
                  child: _StatCell(stat: stat, inline: inline),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({required this.stat, required this.inline});

  final Stat stat;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final value = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(stat.icon, size: 15, color: scheme.primary),
        const SizedBox(width: 5),
        Text(
          stat.value,
          style: textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
    final label = Text(
      stat.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
    );
    return Semantics(
      label: '${stat.label}: ${stat.value}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
        child: inline
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  value,
                  const SizedBox(width: 6),
                  Flexible(child: label),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FittedBox(fit: BoxFit.scaleDown, child: value),
                  label,
                ],
              ),
      ),
    );
  }
}
