import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../services/lead_repository.dart';
import '../theme/app_theme.dart';
import 'gemini_key_dialog.dart';

/// Short notices above the feed: a failed search (with Retry) and a warning
/// from the last search. Each can be closed; it comes back only with the
/// next search. The AI tip is an [AiFilterTip] in the filter chips instead.
class FeedNotices extends StatefulWidget {
  const FeedNotices({super.key});

  @override
  State<FeedNotices> createState() => _FeedNoticesState();
}

class _FeedNoticesState extends State<FeedNotices> {
  /// The search result whose notice the user closed.
  RefreshStatus? _closed;

  @override
  Widget build(BuildContext context) {
    final repository = AppScope.of(context).repository;
    return ListenableBuilder(
      listenable: Listenable.merge([repository.status, repository.offline]),
      builder: (context, _) {
        final status = repository.status.value;
        final open = !identical(status, _closed);
        void close() => setState(() => _closed = status);
        final notices = [
          if (open &&
              status.phase == RefreshPhase.failed &&
              status.message != null)
            Notice(
              key: const ValueKey('error'),
              tone: NoticeTone.error,
              icon: repository.offline.value
                  ? Icons.cloud_off
                  : Icons.error_outline,
              message: status.message!,
              actionLabel: 'Retry',
              onAction: repository.refresh,
              onClose: close,
            ),
          if (open &&
              status.phase == RefreshPhase.succeeded &&
              status.warning != null)
            Notice(
              key: const ValueKey('warning'),
              tone: NoticeTone.warning,
              icon: Icons.info_outline,
              message: status.warning!,
              onClose: close,
            ),
        ];
        return AnimatedSize(
          duration: AppTheme.motionMedium,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final notice in notices)
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.sm),
                  child: notice,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// "AI spam filter is off · Add key ×" as a chip-sized pill, shown in the
/// feed's filter chips until a key is added or it's closed (remembered).
class AiFilterTip extends StatelessWidget {
  const AiFilterTip({super.key});

  @override
  Widget build(BuildContext context) {
    final repository = AppScope.of(context).repository;
    return ListenableBuilder(
      listenable: Listenable.merge([
        repository.aiEnabled,
        repository.aiNoticeDismissed,
      ]),
      builder: (context, _) {
        if (repository.aiEnabled.value || repository.aiNoticeDismissed.value) {
          return const SizedBox.shrink();
        }
        return Notice(
          tone: NoticeTone.info,
          dense: true,
          icon: Icons.auto_awesome_outlined,
          message: 'AI spam filter is off',
          actionLabel: 'Add key',
          onAction: () => GeminiKeyDialog.show(context),
          onClose: repository.dismissAiNotice,
        );
      },
    );
  }
}

enum NoticeTone { info, warning, error }

/// A compact banner: icon, a short message, an optional action and a
/// close button. [dense] makes it a one-line pill sized like a chip.
class Notice extends StatelessWidget {
  const Notice({
    super.key,
    required this.tone,
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.onClose,
    this.dense = false,
  });

  final bool dense;

  final NoticeTone tone;
  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trust = TrustColors.of(context);
    final (background, foreground, accent) = switch (tone) {
      NoticeTone.error => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        scheme.onErrorContainer,
      ),
      NoticeTone.warning => (
        trust.questionable,
        trust.onQuestionable,
        trust.onQuestionable,
      ),
      NoticeTone.info => (
        scheme.surfaceContainerHigh,
        scheme.onSurfaceVariant,
        scheme.primary,
      ),
    };
    if (dense) {
      final textTheme = Theme.of(context).textTheme;
      return Semantics(
        container: true,
        child: Container(
          height: 40,
          padding: const EdgeInsets.only(left: Spacing.sm),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(AppTheme.radiusChip),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: accent),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelLarge?.copyWith(color: foreground),
                ),
              ),
              if (actionLabel != null && onAction != null)
                TextButton(
                  onPressed: onAction,
                  style: TextButton.styleFrom(
                    foregroundColor: accent,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
                    minimumSize: const Size(0, 32),
                    textStyle: textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  child: Text(actionLabel!),
                ),
              if (onClose != null)
                IconButton(
                  tooltip: 'Dismiss',
                  onPressed: onClose,
                  color: foreground,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 40,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.close, size: 16),
                )
              else
                const SizedBox(width: Spacing.sm),
            ],
          ),
        ),
      );
    }
    return Semantics(
      container: true,
      liveRegion: tone == NoticeTone.error,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.only(left: Spacing.sm),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(AppTheme.radiusChip),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: accent),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
                child: Text(
                  message,
                  maxLines: tone == NoticeTone.info ? 2 : 4,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: foreground,
                    fontWeight: tone == NoticeTone.info
                        ? FontWeight.w600
                        : null,
                    height: 1.3,
                  ),
                ),
              ),
            ),
            if (actionLabel != null && onAction != null)
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  foregroundColor: accent,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(actionLabel!),
              ),
            if (onClose != null)
              IconButton(
                tooltip: 'Dismiss',
                onPressed: onClose,
                color: foreground,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
              )
            else
              const SizedBox(width: Spacing.sm),
          ],
        ),
      ),
    );
  }
}
