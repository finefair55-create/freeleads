import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A row of chips or tabs: one swipeable line on phones, so a long list
/// doesn't push the feed down, and wrapped lines on wider screens, where a
/// mouse can't swipe.
class ChipRow extends StatelessWidget {
  const ChipRow({
    super.key,
    required this.children,
    this.padding = Spacing.md,
    this.spacing = Spacing.xs,
    this.controller,
  });

  final List<Widget> children;

  /// Horizontal inset, kept as scrollable space on phones so chips can
  /// scroll to the screen edge.
  final double padding;
  final double spacing;
  final ScrollController? controller;

  /// Narrower than this, the row scrolls instead of wrapping.
  static const wrapWidth = 600.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= wrapWidth) {
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: padding),
            child: Wrap(
              spacing: spacing,
              runSpacing: spacing,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: children,
            ),
          );
        }
        return SingleChildScrollView(
          controller: controller,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: padding),
          child: Row(
            children: [
              for (final (i, chip) in children.indexed) ...[
                if (i > 0) SizedBox(width: spacing),
                chip,
              ],
            ],
          ),
        );
      },
    );
  }
}
