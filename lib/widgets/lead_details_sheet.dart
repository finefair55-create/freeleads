import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../models/lead.dart';
import '../theme/app_theme.dart';
import 'format.dart';
import 'lead_badges.dart';
import 'link_opener.dart';
import 'reply_button.dart';

Future<void> showLeadDetails(BuildContext context, Lead lead) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    sheetAnimationStyle: const AnimationStyle(
      duration: AppTheme.motionSlow,
      reverseDuration: AppTheme.motionMedium,
    ),
    builder: (_) => _LeadDetailsSheet(leadId: lead.id, initial: lead),
  );
}

class _LeadDetailsSheet extends StatelessWidget {
  const _LeadDetailsSheet({required this.leadId, required this.initial});

  final String leadId;
  final Lead initial;

  @override
  Widget build(BuildContext context) {
    final repository = AppScope.of(context).repository;
    return ValueListenableBuilder<List<Lead>>(
      valueListenable: repository.leads,
      builder: (context, leads, _) {
        final lead = leads.where((l) => l.id == leadId).firstOrNull ?? initial;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          builder: (context, controller) => _content(context, lead, controller),
        );
      },
    );
  }

  Widget _content(
    BuildContext context,
    Lead lead,
    ScrollController controller,
  ) {
    final repository = AppScope.of(context).repository;
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final posted = lead.postedAt ?? lead.createdAt;

    final hairline = scheme.outlineVariant.withValues(alpha: 0.6);

    final details = ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.xl),
      children: [
        // The trust tier gets its own panel below, so only the source here.
        Align(
          alignment: Alignment.centerLeft,
          child: SourceBadge(lead: lead),
        ),
        const SizedBox(height: Spacing.sm),
        Text(lead.displayTitle, style: textTheme.headlineSmall),
        const SizedBox(height: Spacing.md),
        Row(
          children: [
            Expanded(
              child: _Fact(
                label: 'Budget',
                value: lead.budgetLabel,
                accent: true,
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Expanded(
              child: _Fact(
                label: 'Category',
                value: lead.category.isEmpty ? 'Other' : lead.category,
              ),
            ),
            const SizedBox(width: Spacing.xs),
            Expanded(
              child: _Fact(
                label: 'Posted',
                value: posted == null ? 'Unknown' : timeAgo(posted),
              ),
            ),
          ],
        ),
        if (lead.trust != null) ...[
          const SizedBox(height: Spacing.md),
          _TrustPanel(lead: lead),
        ],
        const SizedBox(height: Spacing.md),
        Container(
          padding: const EdgeInsets.fromLTRB(
            Spacing.md,
            Spacing.md,
            Spacing.xxs,
            Spacing.xxs,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
            border: Border.all(color: hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Field(
                icon: Icons.place_outlined,
                label: 'Location',
                value: [
                  if (lead.location.isNotEmpty) lead.location,
                  if (lead.zipCode.isNotEmpty) lead.zipCode,
                ].join(' · '),
              ),
              _Field(
                icon: Icons.contact_phone_outlined,
                label: 'Contact',
                value:
                    lead.contactInfo ??
                    (lead.sourceUrl != null
                        ? 'No direct contact listed. Reply through the original posting.'
                        : 'No contact listed.'),
                copyable: lead.contactInfo != null,
              ),
              _ContactButtons(lead: lead),
              if (lead.sourceUrl != null)
                _Field(
                  icon: Icons.link,
                  label: 'Original listing',
                  value: lead.sourceUrl!,
                  copyable: true,
                  onOpen: () => openExternalLink(context, lead.sourceUrl),
                ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.lg),
        Text('Details', style: textTheme.titleMedium),
        const SizedBox(height: 4),
        SelectableText(
          lead.description,
          style: textTheme.bodyLarge?.copyWith(height: 1.4),
        ),
        if (repository.canDelete(lead)) ...[
          const SizedBox(height: Spacing.xl),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
              onPressed: () async {
                final navigator = Navigator.of(context);
                final sheet = ModalRoute.of(context);
                // Dismissing a scraped lead is cheap; deleting a post or
                // import can't be undone, so confirm first.
                if (lead.source != LeadSource.scraped) {
                  final shared = repository.isSharedPost(lead);
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('Delete this lead?'),
                      content: Text(
                        shared
                            ? 'It will be removed for everyone. This cannot '
                                  'be undone.'
                            : 'It will be removed from this device. This '
                                  'cannot be undone.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true) {
                    return;
                  }
                }
                try {
                  await repository.deleteLead(lead);
                } catch (error) {
                  debugPrint('Deleting ${lead.id} failed: $error');
                }
                // A second tap while the first delete ran must not pop
                // the screen under the sheet.
                if (sheet?.isCurrent ?? false) {
                  navigator.pop();
                }
              },
              icon: const Icon(Icons.delete_outline),
              label: Text(
                lead.source == LeadSource.scraped ? 'Dismiss' : 'Delete',
              ),
            ),
          ),
        ],
      ],
    );

    final save = FilledButton.tonalIcon(
      onPressed: () => repository.toggleFavorite(lead),
      icon: Icon(lead.isFavorite ? Icons.star : Icons.star_border),
      label: Text(lead.isFavorite ? 'Saved' : 'Save'),
    );
    // Reply and Save stay pinned under the scrolling details.
    return Column(
      children: [
        Expanded(child: details),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: hairline)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.md,
                Spacing.sm,
                Spacing.md,
                Spacing.sm,
              ),
              child: Row(
                children: [
                  if (ReplyButton.canReply(lead)) ...[
                    Expanded(child: ReplyButton(lead: lead)),
                    const SizedBox(width: Spacing.sm),
                    save,
                  ] else
                    Expanded(child: save),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One labeled key fact in the tile row under the title.
class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.accent = false});

  final String label;
  final String value;

  /// Shows [value] in the accent color (the budget).
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.sm - 2,
      ),
      decoration: BoxDecoration(
        color: accent
            ? scheme.primaryContainer.withValues(alpha: 0.55)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: accent ? scheme.primary : null,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.icon,
    required this.label,
    required this.value,
    this.copyable = false,
    this.onOpen,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool copyable;

  /// Renders [value] as a link that calls this when tapped.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                if (onOpen == null)
                  SelectableText(value)
                else
                  Semantics(
                    link: true,
                    child: InkWell(
                      onTap: onOpen,
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          value,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.primary,
                            decoration: TextDecoration.underline,
                            decorationColor: scheme.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (onOpen != null)
            IconButton(
              tooltip: 'Open in browser',
              icon: const Icon(Icons.open_in_new, size: 18),
              onPressed: onOpen,
            ),
          if (copyable)
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('$label copied')));
              },
            ),
        ],
      ),
    );
  }
}

/// The lead's trust tier, why, and who graded it. Leads that aren't
/// reliable also get safety tips.
class _TrustPanel extends StatelessWidget {
  const _TrustPanel({required this.lead});

  final Lead lead;

  @override
  Widget build(BuildContext context) {
    final trust = lead.trust!;
    final (background, foreground) = TrustColors.of(context).colorsFor(trust);
    final textTheme = Theme.of(context).textTheme;
    final body = textTheme.bodyMedium?.copyWith(color: foreground);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(trustIcon(trust), color: foreground, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  trust.label,
                  style: textTheme.titleSmall?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                lead.trustByAi ? 'Graded by Gemini' : 'Checked on this device',
                style: textTheme.labelSmall?.copyWith(color: foreground),
              ),
            ],
          ),
          for (final reason in lead.trustReasons) ...[
            const SizedBox(height: 4),
            Text('• $reason', style: body),
          ],
          if (trust != LeadTrust.reliable) ...[
            const SizedBox(height: 8),
            Text(
              'Stay safe: never pay a fee to get a job, never share a '
              'verification code, and keep payment talk off chat apps.',
              style: body?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }
}

/// Call / Text / Email buttons for the contact details in the listing.
class _ContactButtons extends StatelessWidget {
  const _ContactButtons({required this.lead});

  final Lead lead;

  @override
  Widget build(BuildContext context) {
    final actions = contactActions(
      lead.contactInfo,
      subject: lead.title.trim().isEmpty ? null : 'Re: ${lead.displayTitle}',
    );
    if (actions.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(left: 32, bottom: Spacing.sm),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final action in actions)
            OutlinedButton.icon(
              onPressed: () => openContact(context, action),
              icon: Icon(action.icon, size: 18),
              label: Text(action.label),
            ),
        ],
      ),
    );
  }
}
