import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../config/app_config.dart';
import '../services/lead_repository.dart';
import '../theme/app_theme.dart';
import 'format.dart';
import 'motion.dart';

/// The feed's control panel in one card: the search area, how fresh the
/// feed is and the search action on top, then [filters] (the trade and
/// category chips) and [stats], with a progress bar while a search runs.
/// [onEdit] opens the Profile tab to change the ZIP or radius.
class SearchProfileBar extends StatelessWidget {
  const SearchProfileBar({super.key, this.onEdit, this.filters, this.stats});

  final VoidCallback? onEdit;

  /// A chip row under the search line, scrolled within the card's inset.
  final Widget? filters;

  /// A slim summary along the bottom, under a hairline.
  final Widget? stats;

  /// From this width the search button gets its full label.
  static const _roomyWidth = 520.0;

  @override
  Widget build(BuildContext context) {
    final repository = AppScope.of(context).repository;
    return Card(
      clipBehavior: Clip.antiAlias,
      // Its chips and buttons stay separate for screen readers.
      semanticContainer: false,
      child: ListenableBuilder(
        listenable: Listenable.merge([repository.profile, repository.status]),
        builder: (context, _) {
          final running = repository.status.value.isRunning;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.sm,
                  Spacing.sm,
                  Spacing.sm,
                  0,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final roomy = constraints.maxWidth >= _roomyWidth;
                    return Row(
                      children: [
                        Expanded(child: _Summary(onEdit: onEdit)),
                        const SizedBox(width: Spacing.xs),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: roomy ? 240 : constraints.maxWidth * 0.4,
                          ),
                          child: SearchButton(compact: !roomy),
                        ),
                      ],
                    );
                  },
                ),
              ),
              if (filters != null)
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.sm),
                  child: filters,
                ),
              if (stats != null) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(
                    Spacing.sm,
                    Spacing.sm,
                    Spacing.sm,
                    0,
                  ),
                  child: Divider(height: 1),
                ),
                stats!,
              ] else
                const SizedBox(height: Spacing.sm),
              AnimatedOpacity(
                opacity: running ? 1 : 0,
                duration: AppTheme.motionMedium,
                child: LinearProgressIndicator(
                  minHeight: 3,
                  value: running ? null : 0,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({this.onEdit});

  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final repository = scope.repository;
    final profile = repository.profile.value;
    final status = repository.status.value;
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final line = _statusLine(status, scope.pipeline.sourceNames);
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(AppTheme.radiusChip),
          ),
          child: Icon(
            Icons.place_outlined,
            color: scheme.onPrimaryContainer,
            size: 20,
          ),
        ),
        const SizedBox(width: Spacing.xs + 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                profile == null
                    ? 'Set up your search'
                    : 'Within ${profile.radiusMiles} mi of ${profile.zipCode}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              AnimatedSwitcher(
                duration: AppTheme.motionFast,
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.topLeft,
                  children: [...previous, ?current],
                ),
                child: Text(
                  line,
                  key: ValueKey(line),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (onEdit != null)
          IconButton(
            tooltip: 'Edit search area',
            onPressed: onEdit,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.tune, size: 22),
          ),
      ],
    );
  }

  /// Progress while searching; otherwise when the feed was last updated and
  /// what that search found. A failed search shows in a banner instead.
  static String _statusLine(RefreshStatus status, String sources) {
    if (status.isRunning) {
      return status.message ?? 'Searching…';
    }
    final last = status.lastRefresh;
    final parts = [
      if (last != null) 'Updated ${timeAgo(last)}',
      if (status.phase == RefreshPhase.succeeded && status.message != null)
        status.message!,
    ];
    if (parts.isEmpty) {
      return 'Searches $sources for the last '
          '${AppConfig.scrapedLeadRetention.inDays} days';
    }
    return parts.join(' · ');
  }
}

/// The feed's primary action: starts a search of every source, and turns
/// into a progress state while one runs. [compact] fits a phone's header
/// row: a square icon button once there are leads, "Search" before.
class SearchButton extends StatelessWidget {
  const SearchButton({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final repository = AppScope.of(context).repository;
    return ListenableBuilder(
      listenable: Listenable.merge([repository.status, repository.leads]),
      builder: (context, _) {
        final running = repository.status.value.isRunning;
        final empty = repository.leads.value.isEmpty;
        final label = switch ((running, empty, compact)) {
          (true, _, _) => 'Searching…',
          (_, true, false) => 'Start lead search',
          (_, true, true) => 'Search',
          (_, false, _) => 'Refresh leads',
        };
        final iconOnly = compact && !empty;
        final scheme = Theme.of(context).colorScheme;
        return Tooltip(
          message: iconOnly ? label : 'Search now',
          child: Pressable(
            borderRadius: AppTheme.radiusMedium,
            child: FilledButton(
              onPressed: running ? null : repository.refresh,
              style: FilledButton.styleFrom(
                minimumSize: Size(iconOnly ? 44 : 0, 44),
                padding: iconOnly
                    ? EdgeInsets.zero
                    : const EdgeInsets.symmetric(horizontal: Spacing.md),
                disabledBackgroundColor: scheme.primary.withValues(alpha: 0.14),
                disabledForegroundColor: scheme.primary,
              ),
              child: AnimatedSwitcher(
                duration: AppTheme.motionFast,
                child: Row(
                  key: ValueKey(label),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (running)
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: scheme.primary,
                        ),
                      )
                    else
                      Icon(
                        empty ? Icons.travel_explore : Icons.refresh,
                        size: 20,
                      ),
                    if (!iconOnly) ...[
                      const SizedBox(width: Spacing.xs),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
