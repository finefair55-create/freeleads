import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../config/app_config.dart';
import '../models/lead_trust.dart';
import '../sources/listing_source.dart';
import '../theme/app_theme.dart';
import '../widgets/gemini_key_dialog.dart';
import '../widgets/lead_badges.dart';
import '../widgets/search_profile_form.dart';
import 'import_listing_screen.dart';

/// The pro's saved defaults (trade, home ZIP, radius), lead-quality and
/// source settings, and tools: importing a listing by hand and managing the
/// Gemini key.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repository = AppScope.of(context).repository;
    // Rebuilds when a Gemini key is added or removed, here or in the feed.
    return ListenableBuilder(
      listenable: repository.aiEnabled,
      builder: (context, _) => _list(context),
    );
  }

  Widget _list(BuildContext context) {
    final scope = AppScope.of(context);
    final repository = scope.repository;
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final gemini = repository.aiEnabled.value;
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        padding: Spacing.page(constraints.maxWidth),
        children: [
          Text(
            'Your profile',
            style: textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Saved on this device and used for every search.',
            style: textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          _Section(
            icon: Icons.tune,
            title: 'Default search',
            body: 'The work you do and the area you cover.',
            child: SearchProfileForm(
              submitLabel: 'Save',
              submitIcon: Icons.check,
              onSaved: (changed) => ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    changed
                        ? 'Saved. Searching for leads in your area…'
                        : 'No changes. Searching for new leads…',
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _Section(
            icon: Icons.shield_outlined,
            title: 'Lead quality',
            body: gemini
                ? 'Gemini grades every lead, and on-device checks catch common '
                      'scams it might miss.'
                : 'Leads are graded with on-device checks. Add a Gemini key '
                      'below for sharper grading.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final trust in LeadTrust.values)
                      TrustBadge(trust: trust),
                  ],
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<bool>(
                  valueListenable: repository.hideSpam,
                  builder: (context, hide, _) => SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Hide possible spam'),
                    subtitle: const Text('From the feed and the map'),
                    value: hide,
                    onChanged: repository.setHideSpam,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _Section(
            icon: Icons.travel_explore,
            title: 'Sources',
            body:
                'Searched from this phone at a gentle pace with a fixed hourly '
                'limit, covering the last '
                '${AppConfig.scrapedLeadRetention.inDays} days. If a site '
                'pushes back, FreeLeads pauses it instead of retrying.',
            child: ValueListenableBuilder(
              valueListenable: repository.status,
              builder: (context, _, _) => Column(
                children: [
                  for (final source in scope.pipeline.sources)
                    _SourceTile(source: source),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _Section(
            icon: Icons.content_paste_go,
            title: 'Import a listing',
            body:
                'Got a job by text, email or from another site? Paste it and '
                'FreeLeads turns it into a lead.',
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => ImportListingScreen.open(context),
                icon: const Icon(Icons.content_paste),
                label: const Text('Import listing text'),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _Section(
            icon: Icons.auto_awesome,
            title: 'AI cleanup',
            body: gemini
                ? 'On. Gemini filters spam and tidies up listings '
                      '(${scope.gemini.model}).'
                : 'Off. Listings are filtered by keyword only, so some spam '
                      'gets through. Add a free key from Google AI Studio.',
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => GeminiKeyDialog.show(context),
                icon: const Icon(Icons.key),
                label: Text(
                  repository.hasUserGeminiKey || !gemini
                      ? 'Manage API key'
                      : 'Use my own API key',
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _Section(
            icon: Icons.contrast,
            title: 'Appearance',
            body: 'Dark mode also darkens the map.',
            child: ValueListenableBuilder<ThemeMode>(
              valueListenable: repository.themeMode,
              builder: (context, mode, _) => SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.system,
                    icon: Icon(Icons.brightness_auto_outlined),
                    label: Text('System'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    icon: Icon(Icons.light_mode_outlined),
                    label: Text('Light'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    icon: Icon(Icons.dark_mode_outlined),
                    label: Text('Dark'),
                  ),
                ],
                selected: {mode},
                onSelectionChanged: (value) =>
                    repository.setThemeMode(value.single),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _Section(
            icon: scope.firestore.isAvailable
                ? Icons.cloud_done_outlined
                : Icons.phone_android,
            title: 'Direct customer posts',
            body: scope.firestore.isAvailable
                ? 'Leads you post (after signing in with Google) are shared '
                      'with pros in your ZIP area. Without a connection they '
                      'are saved and sent later.'
                : 'Sharing is not available on this device, so leads you '
                      'post stay on this device.',
            child: const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// A titled card on the Profile tab: icon, title, a line of explanation
/// and the controls.
class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.body,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 20, color: scheme.onPrimaryContainer),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              body,
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.source});

  final ListingSource source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = source.status;
    final paused = status.pausedUntil;
    final String detail;
    if (!source.isSupported) {
      detail = 'Not available on this platform';
    } else if (paused != null) {
      final local = TimeOfDay.fromDateTime(paused.toLocal());
      detail = 'Paused until ${local.format(context)} to protect your network';
    } else {
      detail =
          '${status.requestsLastHour} of ${status.hourlyLimit} requests used '
          'this hour';
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        paused != null
            ? Icons.pause_circle_outline
            : Icons.check_circle_outline,
        color: paused != null ? scheme.error : scheme.primary,
      ),
      title: Text(source.label),
      subtitle: Text(detail),
    );
  }
}
