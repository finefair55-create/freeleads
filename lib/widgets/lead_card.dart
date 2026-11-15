import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/lead.dart';
import '../theme/app_theme.dart';
import 'format.dart';
import 'lead_badges.dart';
import 'motion.dart';
import 'reply_button.dart';

/// A lead at a glance: trade, budget, title and place, with Reply (and
/// Show on map) right on the card. A tap opens the full details.
class LeadCard extends StatelessWidget {
  const LeadCard({
    super.key,
    required this.lead,
    this.onTap,
    this.onFavorite,
    this.onShowOnMap,
  });

  final Lead lead;
  final VoidCallback? onTap;
  final VoidCallback? onFavorite;

  /// Opens the lead on the Map tab. Leads without a ZIP have no map button.
  final VoidCallback? onShowOnMap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final trust = lead.trust;
    // Phone cards are ~320px wide, too narrow for a long budget, both
    // badges and the star at full size. The budget gets up to 42% of the
    // row; the badges share the rest, and the trust badge is the last
    // thing to shrink.
    Widget header(double width) => Row(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => Row(
              children: [
                if (trust != null) ...[
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: math.max(0, constraints.maxWidth - 6),
                    ),
                    child: TrustBadge(trust: trust, dense: true),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(child: _CategoryPill(label: lead.category)),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width * 0.42),
          child: Text(
            lead.budgetLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: textTheme.titleMedium?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        if (onFavorite != null)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: lead.isFavorite ? 'Remove from saved' : 'Save lead',
            onPressed: onFavorite,
            icon: Icon(
              lead.isFavorite ? Icons.star : Icons.star_border,
              color: lead.isFavorite ? Colors.amber.shade700 : null,
            ),
          ),
      ],
    );

    final title = Text(
      lead.displayTitle,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.25,
      ),
    );

    final description = Text(
      lead.description,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
        height: 1.35,
      ),
    );

    final place = [
      if (lead.location.isNotEmpty) lead.location,
      if (lead.zipCode.isNotEmpty) lead.zipCode,
    ].join(' · ');
    final age = timeAgo(
      lead.sortTime.millisecondsSinceEpoch == 0 ? null : lead.sortTime,
    );

    final muted = textTheme.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final onShowOnMap = Lead.normalizeZip(lead.zipCode) == null
        ? null
        : this.onShowOnMap;
    // Where the lead came from, whether it has contact details, and when.
    Widget meta(double width) => Row(
      children: [
        Flexible(child: SourceBadge(lead: lead)),
        if (lead.contactInfo != null) ...[
          const SizedBox(width: 6),
          Tooltip(
            message: 'Contact info included',
            child: Icon(
              Icons.contact_phone_outlined,
              size: 15,
              color: scheme.primary,
            ),
          ),
        ],
        if (age.isNotEmpty) ...[
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width * 0.3),
            child: Text(
              age,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
          ),
        ],
      ],
    );

    // The place (a Show on map button when it has a ZIP) and Reply, on a
    // row as tall as Reply even without it, so cards side by side line up.
    final canReply = ReplyButton.canReply(lead);
    Widget actions(double width) => ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40),
      child: Row(
        children: [
          if (onShowOnMap != null)
            Flexible(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _MapButton(place: place, onPressed: onShowOnMap),
              ),
            )
          else ...[
            Icon(
              Icons.place_outlined,
              size: 15,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 3),
            Expanded(
              child: Text(
                place.isEmpty ? 'Location not listed' : place,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
            ),
          ],
          if (canReply) ...[
            const SizedBox(width: Spacing.sm),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: width * 0.45),
              child: ReplyButton(lead: lead, style: _replyStyle),
            ),
          ],
        ],
      ),
    );

    return Pressable(
      raised: true,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            // 16 on every side: the header row's star button brings its
            // own 8 at the top and right.
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.xs,
              Spacing.xs,
              Spacing.md,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final bounded = constraints.hasBoundedHeight;
                final width = constraints.maxWidth;
                final body = Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: description,
                );
                return Column(
                  mainAxisSize: bounded ? MainAxisSize.max : MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    header(width),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: title,
                    ),
                    const SizedBox(height: 6),
                    // In a fixed-height cell (large text, long title) the
                    // description gives up its lines first, so the card
                    // never overflows.
                    if (bounded)
                      Expanded(
                        child: ClipRect(
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: body,
                          ),
                        ),
                      )
                    else
                      body,
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: meta(width - 8),
                    ),
                    const SizedBox(height: Spacing.sm),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: actions(width - 8),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Reply on a card: compact, but still a 40px target.
const _replyStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(0, 40)),
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
  visualDensity: VisualDensity.compact,
);

/// The card's place as a tinted pill with a map icon: tapping it shows the
/// lead on the Map tab.
class _MapButton extends StatelessWidget {
  const _MapButton({required this.place, required this.onPressed});

  final String place;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppTheme.radiusPill);
    // Its own node, so screen readers reach it apart from the card's tap.
    return Semantics(
      container: true,
      button: true,
      label: 'Show on map, $place',
      onTap: onPressed,
      excludeSemantics: true,
      child: Tooltip(
        message: 'Show on map',
        child: Material(
          color: scheme.primaryContainer,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: onPressed,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.map_outlined,
                      size: 16,
                      color: scheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        place,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryPill extends StatelessWidget {
  const _CategoryPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
