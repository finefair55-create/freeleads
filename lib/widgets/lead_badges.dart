import 'package:flutter/material.dart';

import '../models/lead.dart';
import '../sources/listing_source.dart';
import '../theme/app_theme.dart';

IconData trustIcon(LeadTrust trust) => switch (trust) {
  LeadTrust.reliable => Icons.verified_outlined,
  LeadTrust.questionable => Icons.help_outline,
  LeadTrust.spam => Icons.report_gmailerrorred,
};

/// Color-coded trust tier. Always shows the label too, so the tier never
/// relies on color alone.
class TrustBadge extends StatelessWidget {
  const TrustBadge({super.key, required this.trust, this.dense = false});

  final LeadTrust trust;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = TrustColors.of(context).colorsFor(trust);
    return Semantics(
      label: 'Trust: ${trust.label}',
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 8 : 10,
          vertical: dense ? 3 : 4,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(999),
          // A hairline in the badge's own tone keeps the pill's edge crisp
          // on tinted card surfaces in both themes.
          border: Border.all(color: foreground.withValues(alpha: 0.22)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(trustIcon(trust), size: dense ? 13 : 15, color: foreground),
            SizedBox(width: dense ? 3 : 5),
            Flexible(
              child: Text(
                trust.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.1,
                  height: 1.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Where a lead came from: the site it was found on ("Craigslist"), or
/// "Direct Customer" / "Imported".
String sourceLabel(Lead lead) {
  final board = boardLabel(lead.boardId);
  return board.isEmpty ? lead.source.label : board;
}

IconData sourceIcon(Lead lead) => switch (lead.source) {
  LeadSource.scraped => switch (lead.boardId) {
    'craigslist' => Icons.view_list_rounded,
    _ => Icons.travel_explore,
  },
  LeadSource.parsed => Icons.content_paste,
  LeadSource.internal => Icons.person_pin_rounded,
};

/// (background, foreground) for the lead's source badge.
(Color, Color) sourceColors(BuildContext context, Lead lead) {
  final colors = SourceColors.of(context);
  return switch (lead.source) {
    LeadSource.scraped => switch (lead.boardId) {
      'craigslist' => colors.craigslist,
      _ => colors.other,
    },
    LeadSource.parsed => colors.imported,
    LeadSource.internal => colors.direct,
  };
}

/// Tinted pill naming where a lead came from, colored per source so the
/// feed can be scanned by site.
class SourceBadge extends StatelessWidget {
  const SourceBadge({super.key, required this.lead});

  final Lead lead;

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = sourceColors(context, lead);
    return Semantics(
      label: 'Source: ${sourceLabel(lead)}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 3, 8, 3),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(sourceIcon(lead), size: 12, color: foreground),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                sourceLabel(lead),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: foreground, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
