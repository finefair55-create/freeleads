import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/lead.dart';
import '../models/trade.dart';
import '../services/lead_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/app_logo.dart';
import '../widgets/chip_row.dart';
import '../widgets/feed_notices.dart';
import '../widgets/format.dart';
import '../widgets/lead_card.dart';
import '../widgets/lead_details_sheet.dart';
import '../widgets/motion.dart';
import '../widgets/safe_async.dart';
import '../widgets/search_profile_bar.dart';
import '../widgets/skeleton.dart';
import '../widgets/stat_strip.dart';
import '../widgets/trade_picker.dart';
import 'map_screen.dart';
import 'post_lead_screen.dart';
import 'profile_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  /// Tabs opened so far. They stay mounted so switching back keeps their
  /// state (map camera, half-written post); unvisited tabs aren't built.
  final _visited = <int>{0};

  /// Leads whose card has already animated in, so cards scrolled back
  /// into view or re-sorted by a refresh don't fade in again.
  final _shownLeads = <String>{};

  static const _mapTab = 1;
  static const _profileTab = 3;

  /// Feed cards ask the map tab to show their lead through this.
  final _mapFocus = MapFocus();

  void _select(int index) => setState(() {
    _index = index;
    _visited.add(index);
  });

  void _showOnMap(Lead lead) {
    _mapFocus.show(lead);
    _select(_mapTab);
  }

  @override
  void dispose() {
    _mapFocus.dispose();
    super.dispose();
  }

  /// Built once, so switching tabs doesn't rebuild every page: the
  /// [IndexedStack] gets the same widgets back and skips them.
  late final List<Widget> _pages = [
    _LeadsDashboard(
      onEditProfile: () => _select(_profileTab),
      onShowOnMap: _showOnMap,
      shownLeads: _shownLeads,
    ),
    MapScreen(focus: _mapFocus),
    const PostLeadScreen(),
    const ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    const destinations = [
      _NavItem(Icons.dashboard_outlined, Icons.dashboard, 'Leads'),
      _NavItem(Icons.map_outlined, Icons.map, 'Map'),
      _NavItem(Icons.add_box_outlined, Icons.add_box, 'Post'),
      _NavItem(Icons.person_outline, Icons.person, 'Profile'),
    ];

    final body = TabFadeThrough(
      index: _index,
      child: IndexedStack(
        index: _index,
        children: [
          for (var i = 0; i < _pages.length; i++)
            _visited.contains(i) ? _pages[i] : const SizedBox.shrink(),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 960;
        return Scaffold(
          appBar: AppBar(
            title: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppLogo(size: 30),
                SizedBox(width: Spacing.sm),
                Flexible(
                  child: Text('FreeLeads', overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            actions: [
              Center(child: _ModeBadge(live: scope.firestore.isAvailable)),
              const SizedBox(width: Spacing.xxs),
              const _ThemeToggle(),
              const SizedBox(width: Spacing.xs),
            ],
          ),
          body: wide
              ? Row(
                  children: [
                    NavigationRail(
                      selectedIndex: _index,
                      onDestinationSelected: _select,
                      labelType: NavigationRailLabelType.all,
                      destinations: [
                        for (final item in destinations)
                          NavigationRailDestination(
                            icon: Icon(item.icon),
                            selectedIcon: Icon(item.selectedIcon),
                            label: Text(item.label),
                          ),
                      ],
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: body),
                  ],
                )
              : body,
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: _select,
                  destinations: [
                    for (final item in destinations)
                      NavigationDestination(
                        icon: Icon(item.icon),
                        selectedIcon: Icon(item.selectedIcon),
                        label: item.label,
                      ),
                  ],
                ),
        );
      },
    );
  }
}

class _NavItem {
  const _NavItem(this.icon, this.selectedIcon, this.label);
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// One tap between light and dark, from whichever is showing (the system's
/// choice until the user picks). Profile keeps the full System/Light/Dark
/// setting.
class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle();

  @override
  Widget build(BuildContext context) {
    final repository = AppScope.of(context).repository;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IconButton(
      tooltip: dark ? 'Switch to light mode' : 'Switch to dark mode',
      onPressed: () =>
          repository.setThemeMode(dark ? ThemeMode.light : ThemeMode.dark),
      icon: AnimatedSwitcher(
        duration: AppTheme.motionMedium,
        transitionBuilder: (child, animation) => RotationTransition(
          turns: Tween(begin: 0.75, end: 1.0).animate(animation),
          child: FadeTransition(opacity: animation, child: child),
        ),
        child: Icon(
          dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
          key: ValueKey(dark),
        ),
      ),
    );
  }
}

class _ModeBadge extends StatelessWidget {
  const _ModeBadge({required this.live});

  final bool live;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: AppScope.of(context).repository.offline,
      builder: (context, offline, _) {
        // Narrow screens and large text get the short wording, so the
        // title keeps its room.
        final width = MediaQuery.sizeOf(context).width;
        final roomy = width >= 420 * MediaQuery.textScalerOf(context).scale(1);
        final (label, color, icon) = offline
            ? ('Offline', scheme.surfaceContainerHighest, Icons.cloud_off)
            : live
            ? (
                roomy ? 'Direct posts live' : 'Live',
                scheme.primaryContainer,
                null,
              )
            : (
                roomy ? 'On-device only' : 'On-device',
                scheme.secondaryContainer,
                null,
              );
        return AnimatedContainer(
          constraints: BoxConstraints(maxWidth: width * 0.45),
          duration: AppTheme.motionMedium,
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(AppTheme.radiusPill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null)
                Icon(icon, size: 14)
              else
                // Status light: accent when posts sync, neutral when not.
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: live ? scheme.primary : scheme.outline,
                  ),
                ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LeadsDashboard extends StatefulWidget {
  const _LeadsDashboard({
    required this.onEditProfile,
    required this.onShowOnMap,
    required this.shownLeads,
  });

  final VoidCallback onEditProfile;
  final ValueChanged<Lead> onShowOnMap;

  /// Owned by [HomeScreen], so it outlives this tab's state.
  final Set<String> shownLeads;

  @override
  State<_LeadsDashboard> createState() => _LeadsDashboardState();
}

class _LeadsDashboardState extends State<_LeadsDashboard> {
  static const _all = 'All';
  static const _saved = 'Saved';
  static const _direct = 'Direct Customer';

  /// Past this the feed stops growing and centers, so cards and the search
  /// button don't stretch across a desktop monitor.
  static const _maxContentWidth = 1200.0;

  String _category = _all;

  /// Trade the category filter was picked under; a new trade starts over
  /// at All, since its leads have different categories.
  String? _trade;

  static bool _isDirect(Lead lead) => lead.source == LeadSource.internal;

  /// Hourly and daily rates aren't job budgets, so they'd skew the average.
  static final _rate = RegExp(
    r'/ ?(?:h(?:ou)?r|day)|per (?:hour|day)|an hour|a day|hourly|daily',
    caseSensitive: false,
  );

  void _onCategoryChanged(String value) {
    if (value != _category) {
      setState(() => _category = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shownLeads = widget.shownLeads;
    final repository = AppScope.of(context).repository;
    return LayoutBuilder(
      builder: (context, constraints) {
        final gutter = math.max(
          Spacing.md,
          (constraints.maxWidth - _maxContentWidth) / 2,
        );
        return ListenableBuilder(
          listenable: Listenable.merge([
            repository.leads,
            repository.hideSpam,
            repository.profile,
          ]),
          builder: (context, _) =>
              _feed(context, repository, shownLeads, gutter),
        );
      },
    );
  }

  Widget _feed(
    BuildContext context,
    LeadRepository repository,
    Set<String> shownLeads,
    double gutter,
  ) {
    final trade = repository.profile.value?.profession;
    // For the empty feed: "new plumbing requests".
    final requests = trade == null || trade.trim().isEmpty
        ? 'new requests'
        : 'new ${Trade.displayName(trade).toLowerCase()} requests';
    if (trade != _trade) {
      _trade = trade;
      _category = _all;
    }
    final all = repository.leads.value;
    final leads = repository.visible(all);
    final hiddenSpam = all.length - leads.length;
    final hasSpam = all.any((lead) => lead.trust == LeadTrust.spam);
    final categories = {
      _all,
      if (leads.any((lead) => lead.isFavorite)) _saved,
      if (leads.any(_isDirect)) _direct,
      for (final lead in leads)
        if (lead.category.isNotEmpty) lead.category,
    };
    final selected = categories.contains(_category) ? _category : _all;
    final visible = switch (selected) {
      _all => leads,
      _saved => leads.where((lead) => lead.isFavorite).toList(),
      _direct => leads.where(_isDirect).toList(),
      _ => leads.where((lead) => lead.category == selected).toList(),
    };
    // The summary describes what's on screen, so it follows the filter.
    final budgets = [
      for (final lead in visible)
        if (lead.price != null && !_rate.hasMatch(lead.budget ?? ''))
          lead.price!,
    ];
    final today = visible
        .where(
          (lead) =>
              DateTime.now().difference(lead.sortTime) <
              const Duration(hours: 24),
        )
        .length;

    EdgeInsets inset({double top = Spacing.sm}) =>
        EdgeInsets.fromLTRB(gutter, top, gutter, 0);

    return RefreshIndicator(
      onRefresh: repository.refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // One control panel: the area and Refresh, the trade and what's
          // shown of its leads, and a summary of what's on screen.
          SliverPadding(
            padding: inset(top: Spacing.xs),
            sliver: SliverToBoxAdapter(
              child: SearchProfileBar(
                onEdit: widget.onEditProfile,
                filters: ChipRow(
                  padding: Spacing.sm,
                  children: [
                    TradePicker(onOther: widget.onEditProfile, inline: true),
                    if (all.isNotEmpty) ...[
                      for (final item in categories)
                        Pressable(
                          scale: 0.96,
                          borderRadius: AppTheme.radiusChip,
                          child: ChoiceChip(
                            avatar: switch (item) {
                              _saved => const Icon(Icons.star, size: 16),
                              _direct => const Icon(
                                Icons.person_pin_rounded,
                                size: 16,
                              ),
                              _ => null,
                            },
                            label: Text(item),
                            selected: selected == item,
                            showCheckmark: false,
                            onSelected: (_) => _onCategoryChanged(item),
                          ),
                        ),
                      if (hasSpam || repository.hideSpam.value)
                        Pressable(
                          scale: 0.96,
                          borderRadius: AppTheme.radiusChip,
                          child: FilterChip(
                            avatar: const Icon(Icons.shield_outlined, size: 16),
                            label: Text(
                              hiddenSpam > 0
                                  ? 'Possible spam hidden ($hiddenSpam)'
                                  : 'Hide possible spam',
                            ),
                            selected: repository.hideSpam.value,
                            showCheckmark: false,
                            onSelected: repository.setHideSpam,
                          ),
                        ),
                    ],
                    const AiFilterTip(),
                  ],
                ),
                stats: all.isEmpty
                    ? null
                    : StatStrip(
                        stats: [
                          (
                            label: 'Open leads',
                            value: '${visible.length}',
                            icon: Icons.bolt_outlined,
                          ),
                          (
                            label: 'Last 24 hours',
                            value: '$today',
                            icon: Icons.schedule_outlined,
                          ),
                          (
                            label: 'Avg. budget',
                            value: budgets.isEmpty
                                ? '—'
                                : formatDollars(
                                    budgets.reduce((a, b) => a + b) /
                                        budgets.length,
                                  ),
                            icon: Icons.payments_outlined,
                          ),
                        ],
                      ),
              ),
            ),
          ),
          SliverPadding(
            padding: inset(top: 0),
            sliver: const SliverToBoxAdapter(child: FeedNotices()),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              gutter,
              Spacing.sm,
              gutter,
              Spacing.xl,
            ),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final columns = _columnsFor(constraints.crossAxisExtent);
                // One column: cards take their natural height. Side by
                // side they share a fixed height so rows line up.
                final extent = columns == 1 ? null : _cardExtent(context);
                if (all.isEmpty) {
                  return SliverToBoxAdapter(
                    child: ValueListenableBuilder<RefreshStatus>(
                      valueListenable: repository.status,
                      builder: (context, status, _) {
                        final loading =
                            !repository.isLoaded || status.isRunning;
                        return AnimatedSwitcher(
                          duration: AppTheme.motionMedium,
                          child: loading
                              ? _FeedSkeleton(
                                  columns: columns,
                                  cardHeight: extent,
                                )
                              : StatusPane(
                                  icon: Icons.inbox_outlined,
                                  title: 'No leads yet',
                                  message:
                                      'Start a search to look for '
                                      '$requests near you, or post a lead.',
                                ),
                        );
                      },
                    ),
                  );
                }
                if (visible.isEmpty) {
                  return SliverToBoxAdapter(
                    child: leads.isEmpty
                        ? StatusPane(
                            icon: Icons.shield_outlined,
                            title: 'Only possible spam',
                            message:
                                'Every lead here was graded possible spam, '
                                'so they are hidden.',
                            action: FilledButton.tonal(
                              onPressed: () => repository.setHideSpam(false),
                              child: const Text('Show them anyway'),
                            ),
                          )
                        : StatusPane(
                            icon: Icons.filter_alt_off_outlined,
                            title: 'Nothing here',
                            message: 'No leads match this filter right now.',
                            action: FilledButton.tonal(
                              onPressed: () => _onCategoryChanged(_all),
                              child: const Text('Show all leads'),
                            ),
                          ),
                  );
                }
                Widget card(BuildContext context, int index) {
                  final lead = visible[index];
                  return EntranceFade(
                    key: ValueKey(lead.id),
                    index: index,
                    animate: !shownLeads.contains(lead.id),
                    onShown: () => shownLeads.add(lead.id),
                    child: LeadCard(
                      lead: lead,
                      onTap: () => showLeadDetails(context, lead),
                      onFavorite: () => repository.toggleFavorite(lead),
                      onShowOnMap: () => widget.onShowOnMap(lead),
                    ),
                  );
                }

                if (extent == null) {
                  return SliverList.separated(
                    itemCount: visible.length,
                    itemBuilder: card,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: Spacing.md),
                  );
                }
                return SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisExtent: extent,
                    crossAxisSpacing: Spacing.md,
                    mainAxisSpacing: Spacing.md,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    card,
                    childCount: visible.length,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

int _columnsFor(double width) => width > 1100
    ? 3
    : width > 720
    ? 2
    : 1;

/// Height of a feed card in a multi-column grid. About 160 of its 270px is
/// text, so rows grow with the user's text size (capped; the card trims
/// its description if it still runs out).
double _cardExtent(BuildContext context) {
  final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
  return 110 + 160 * textScale.clamp(1.0, 2.0);
}

/// Shimmering placeholder cards laid out like the feed grid, shown while
/// stored leads load or the first search runs.
class _FeedSkeleton extends StatelessWidget {
  const _FeedSkeleton({required this.columns, this.cardHeight});

  final int columns;

  /// Null for natural-height cards.
  final double? cardHeight;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading leads',
      child: Shimmer(
        child: Column(
          children: [
            for (var row = 0; row < 3; row++) ...[
              if (row > 0) const SizedBox(height: Spacing.md),
              Row(
                children: [
                  for (var col = 0; col < columns; col++) ...[
                    if (col > 0) const SizedBox(width: Spacing.md),
                    Expanded(child: LeadCardSkeleton(height: cardHeight)),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
