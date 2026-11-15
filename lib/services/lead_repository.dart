import 'dart:async';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart';

import '../config/app_config.dart';
import '../models/lead.dart';
import '../models/search_profile.dart';
import '../sources/listing_fetch_service.dart';
import 'firestore_service.dart';
import 'listing_pipeline.dart';
import 'local_lead_store.dart';

enum RefreshPhase { idle, running, succeeded, failed }

enum PostOutcome {
  /// Firestore confirmed the write; nearby pros see it now.
  shared,

  /// Offline: Firestore queued the write and uploads it on reconnect.
  queued,

  /// No Firebase on this platform; saved locally only.
  deviceOnly,
}

@immutable
class RefreshStatus {
  const RefreshStatus({
    this.phase = RefreshPhase.idle,
    this.message,
    this.lastRefresh,
    this.newLeads = 0,
    this.warning,
  });

  final RefreshPhase phase;

  /// Progress while running, the summary after a search, or the error.
  final String? message;
  final DateTime? lastRefresh;
  final int newLeads;

  /// Non-fatal problem from the last search (one source paused, Gemini
  /// quota reached), shown apart from the summary.
  final String? warning;

  bool get isRunning => phase == RefreshPhase.running;
}

/// Single source of truth for the UI: merges on-device leads (scraped,
/// parsed, favorites, offline posts) with live community leads, and owns
/// the scrape → Gemini → Hive refresh cycle, including periodic refresh
/// while the app is in the foreground.
///
/// Owns [pipeline]: [dispose] cancels every timer and subscription,
/// closes the pipeline's HTTP clients and disposes the notifiers, and is
/// safe to call while a refresh is still running.
class LeadRepository with WidgetsBindingObserver {
  LeadRepository({
    required this.local,
    required this.community,
    required this.pipeline,
    this.autoRefreshInterval = AppConfig.autoRefreshInterval,
  }) : profile = ValueNotifier(local.searchProfile),
       hideSpam = ValueNotifier(local.hideSpam),
       themeMode = ValueNotifier(_parseThemeMode(local.themeMode)),
       aiNoticeDismissed = ValueNotifier(local.aiNoticeDismissed),
       status = ValueNotifier(RefreshStatus(lastRefresh: local.lastRefresh)) {
    final storedKey = local.geminiApiKey;
    if (storedKey != null) {
      pipeline.gemini.apiKey = storedKey;
    }
    aiEnabled.value = pipeline.gemini.isConfigured;
  }

  final LocalLeadStore local;
  final FirestoreService community;
  final ListingPipeline pipeline;

  /// Null disables background refresh (used in tests).
  final Duration? autoRefreshInterval;

  final ValueNotifier<SearchProfile?> profile;
  final ValueNotifier<RefreshStatus> status;

  /// Hide leads graded "Possible spam" from the feed and map.
  final ValueNotifier<bool> hideSpam;

  /// Light, dark, or following the system; chosen on the Profile tab.
  final ValueNotifier<ThemeMode> themeMode;

  /// Whether Gemini has a key, so listings get AI cleanup and grading.
  final ValueNotifier<bool> aiEnabled = ValueNotifier(false);

  /// The user closed the feed's "AI filter is off" notice.
  final ValueNotifier<bool> aiNoticeDismissed;

  /// Best guess at connectivity: set when a search can't reach the network
  /// or a post is queued, cleared by the next successful search or post.
  final ValueNotifier<bool> offline = ValueNotifier(false);

  /// Merged, newest-first feed. [isLoaded] flips once local data is read.
  final ValueNotifier<List<Lead>> leads = ValueNotifier(const []);
  bool isLoaded = false;

  List<Lead> _local = const [];
  List<Lead> _community = const [];
  StreamSubscription<List<Lead>>? _localSub;
  StreamSubscription<List<Lead>>? _communitySub;
  Timer? _timer;
  Timer? _offlineRetry;
  Future<void>? _inFlight;

  /// Stored leads whose posting was already reread for a location this
  /// run of the app, so a refresh doesn't fetch the same pages again.
  final Set<String> _relocateChecked = {};
  bool _started = false;
  bool _disposed = false;
  bool _foreground = true;

  /// Subscribes to data sources and, if enabled, starts auto-refresh.
  void start() {
    if (_started) {
      return;
    }
    _started = true;
    _localSub = local.watch().listen((value) {
      _local = value;
      isLoaded = true;
      _publish();
    });
    _subscribeCommunity();
    unawaited(_cleanUp());

    if (autoRefreshInterval != null) {
      WidgetsBinding.instance.addObserver(this);
      _startTimer();
      _refreshIfStale();
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _timer?.cancel();
    _offlineRetry?.cancel();
    if (autoRefreshInterval != null && _started) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _localSub?.cancel();
    _communitySub?.cancel();
    pipeline.close();
    profile.dispose();
    status.dispose();
    hideSpam.dispose();
    themeMode.dispose();
    aiEnabled.dispose();
    aiNoticeDismissed.dispose();
    offline.dispose();
    leads.dispose();
  }

  bool get isDisposed => _disposed;

  /// Background refresh only runs while the app is visible: timers are
  /// stopped when it is hidden and restarted (with a catch-up refresh if
  /// due) when it comes back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _foreground = true;
        _startTimer();
        _refreshIfStale();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _foreground = false;
        _timer?.cancel();
        _timer = null;
        _offlineRetry?.cancel();
        _offlineRetry = null;
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _startTimer() {
    final interval = autoRefreshInterval;
    if (interval == null || _disposed || _timer != null) {
      return;
    }
    _timer = Timer.periodic(interval, (_) => _refreshIfStale());
  }

  /// Startup garbage collection: prunes expired and excess entries, then
  /// compacts the boxes.
  Future<void> _cleanUp() async {
    try {
      final removed = await local.prune(
        AppConfig.scrapedLeadRetention,
        myUid: community.currentUserId,
      );
      await local.compact();
      if (removed > 0) {
        debugPrint('Pruned $removed expired lead(s).');
      }
    } catch (error) {
      debugPrint('Cache clean-up skipped: $error');
    }
  }

  void _setStatus(RefreshStatus value) {
    if (!_disposed) {
      status.value = value;
    }
  }

  void _setOffline(bool value) {
    if (!_disposed) {
      offline.value = value;
    }
  }

  Future<void> setHideSpam(bool value) async {
    hideSpam.value = value;
    await local.saveHideSpam(value);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    await local.saveThemeMode(mode == ThemeMode.system ? null : mode.name);
  }

  static ThemeMode _parseThemeMode(String? name) => switch (name) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  /// [leads] without "Possible spam" when [hideSpam] is on.
  List<Lead> visible(List<Lead> leads) => hideSpam.value
      ? leads.where((lead) => lead.trust != LeadTrust.spam).toList()
      : leads;

  /// Preferences backed up to Firebase, for restoring during onboarding.
  Future<SearchProfile?> remoteProfile() => community.loadProfile();

  bool get geminiConfigured => pipeline.gemini.isConfigured;

  bool get hasUserGeminiKey => (local.geminiApiKey ?? '').isNotEmpty;

  Future<void> setGeminiApiKey(String? key) async {
    await local.saveGeminiApiKey(key);
    pipeline.gemini.apiKey = local.geminiApiKey;
    if (!_disposed) {
      aiEnabled.value = pipeline.gemini.isConfigured;
    }
  }

  Future<void> dismissAiNotice() async {
    aiNoticeDismissed.value = true;
    await local.saveAiNoticeDismissed(true);
  }

  /// Searches for [profession] instead, keeping the ZIP and radius. Like
  /// any trade change it clears the old trade's scraped leads (favorites
  /// stay) and starts a new search.
  Future<void> switchTrade(String profession) async {
    final current = profile.value;
    final next = profession.trim();
    if (current == null ||
        next.isEmpty ||
        current.profession.toLowerCase() == next.toLowerCase()) {
      return;
    }
    await updateProfile(current.copyWith(profession: next));
  }

  /// Saves [next] and refreshes. Changing profession or ZIP clears scraped
  /// leads (except favorites) and the rejected list, since relevance
  /// depends on both.
  Future<void> updateProfile(SearchProfile next) async {
    final previous = profile.value;
    await local.saveSearchProfile(next);
    if (_disposed) {
      return;
    }
    profile.value = next;
    unawaited(community.saveProfile(next));
    final changedScope =
        previous == null ||
        previous.profession.toLowerCase() != next.profession.toLowerCase() ||
        previous.zipCode != next.zipCode;
    // Clear right away, so the feed doesn't keep showing the old trade's
    // leads while a search for it winds down.
    if (changedScope) {
      await _clearScrapedLeads();
      if (_disposed) {
        return;
      }
      if (previous?.zipPrefix != next.zipPrefix) {
        _subscribeCommunity();
      }
    }
    // A search for the previous profile may still be running. It sees the
    // change and discards its results; wait for it so [refresh] starts a
    // new run instead of joining the stale one.
    final stale = _inFlight;
    if (stale != null) {
      _setStatus(
        RefreshStatus(
          phase: RefreshPhase.running,
          message: 'Searching ${pipeline.sourceNames} near ${next.zipCode}…',
          lastRefresh: status.value.lastRefresh,
        ),
      );
      await stale;
      if (_disposed) {
        return;
      }
      // It may have stored its results just before the change.
      if (changedScope) {
        await _clearScrapedLeads();
      }
    }
    await refresh();
  }

  /// Drops scraped leads (except favorites) and forgets rejected listings,
  /// since both depend on the trade and area searched.
  Future<void> _clearScrapedLeads() async {
    final stale = _local
        .where((lead) => lead.source == LeadSource.scraped && !lead.isFavorite)
        .map((lead) => lead.id)
        .toList();
    for (final id in stale) {
      await local.delete(id);
    }
    await local.clearRejected();
  }

  /// Runs the pipeline once. Concurrent calls share the same run.
  Future<void> refresh() {
    return _inFlight ??= _runRefresh().whenComplete(() => _inFlight = null);
  }

  Future<void> _runRefresh() async {
    final current = profile.value;
    if (_disposed) {
      return;
    }
    if (current == null || !current.isValid) {
      _setStatus(
        RefreshStatus(
          phase: RefreshPhase.failed,
          message: 'Enter your trade and a 5-digit ZIP to find leads.',
          lastRefresh: status.value.lastRefresh,
        ),
      );
      return;
    }
    final lastRefresh = status.value.lastRefresh;
    _setStatus(
      RefreshStatus(
        phase: RefreshPhase.running,
        message: 'Searching ${pipeline.sourceNames} near ${current.zipCode}…',
        lastRefresh: lastRefresh,
      ),
    );
    try {
      final report = await pipeline.run(
        current,
        knownIds: local.ids,
        rejectedIds: local.rejectedIds,
        // Leads saved before postings were placed by their map point sit at
        // the search ZIP; reread those, newest first, to move them to their
        // own town.
        relocate: [
          for (final lead in _local)
            if (lead.source == LeadSource.scraped &&
                lead.zipCode == current.zipCode &&
                !_relocateChecked.contains(lead.id))
              lead,
        ]..sort((a, b) => b.sortTime.compareTo(a.sortTime)),
        onProgress: (message) {
          // A search the user has moved on from stays quiet.
          if (identical(profile.value, current)) {
            _setStatus(
              RefreshStatus(
                phase: RefreshPhase.running,
                message: message,
                lastRefresh: lastRefresh,
              ),
            );
          }
        },
      );
      if (_disposed) {
        return;
      }
      if (!identical(profile.value, current)) {
        // The profile changed mid-run; these results are for the old
        // search. [updateProfile] starts a new run and sets the status.
        return;
      }
      _relocateChecked.addAll(report.relocated.keys);
      await local.upsertAll([
        ...report.leads,
        for (final MapEntry(key: id, value: zip) in report.relocated.entries)
          if (zip != null && zip != current.zipCode)
            if (local.get(id) case final stored?) stored.copyWith(zipCode: zip),
      ]);
      if (report.rejectedIds.isNotEmpty) {
        await local.markRejected(report.rejectedIds);
      }
      await local.prune(
        AppConfig.scrapedLeadRetention,
        myUid: community.currentUserId,
      );
      final now = DateTime.now();
      await local.saveLastRefresh(now);
      _setOffline(false);

      final filtered = report.rejectedIds.length - report.tooOld;
      String count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
      final summary = report.found == 0
          ? 'No listings matched "${current.profession}" near ${current.zipCode}.'
          : '${[count(report.leads.length, 'new lead'), if (filtered > 0) '$filtered filtered out', if (report.tooOld > 0) '${report.tooOld} too old'].join(', ')}.';
      _setStatus(
        RefreshStatus(
          phase: RefreshPhase.succeeded,
          message: summary,
          warning: report.warning,
          lastRefresh: now,
          newLeads: report.leads.length,
        ),
      );
    } catch (error, stack) {
      if (_disposed) {
        return;
      }
      debugPrint('Refresh failed: $error');
      if (error is! ListingFetchException) {
        debugPrintStack(stackTrace: stack);
      }
      if (error is ListingFetchException && error.isNetwork) {
        _setOffline(true);
        // Quietly try again so the feed recovers once the signal is back.
        if (autoRefreshInterval != null && _foreground) {
          _offlineRetry?.cancel();
          _offlineRetry = Timer(const Duration(minutes: 2), () {
            if (!_disposed && offline.value) unawaited(refresh());
          });
        }
      }
      _setStatus(
        RefreshStatus(
          phase: RefreshPhase.failed,
          message: _describe(error),
          lastRefresh: lastRefresh,
        ),
      );
    }
  }

  void _refreshIfStale() {
    final interval = autoRefreshInterval;
    if (_disposed || interval == null) {
      return;
    }
    final current = profile.value;
    if (current == null || !current.isValid) {
      return;
    }
    final last = status.value.lastRefresh;
    if (last == null || DateTime.now().difference(last) >= interval) {
      unawaited(refresh());
    }
  }

  Future<void> toggleFavorite(Lead lead) =>
      local.setFavorite(lead, !lead.isFavorite);

  /// Saves an imported lead to the local feed, sanitized and graded.
  Future<void> saveParsedLead(Lead lead) =>
      local.upsert(pipeline.finalize(lead));

  /// Posts a community order. Goes to Firestore when available (queued
  /// there while offline); otherwise it is kept on-device only.
  Future<PostOutcome> postLead(Lead order) async {
    final lead = order.sanitized();
    if (community.isAvailable) {
      final result = await community.postLead(lead);
      // Keep a local copy so the user's own orders work offline too.
      await local.upsert(result.lead);
      final confirmed = result.confirmed;
      _setOffline(!confirmed);
      return confirmed ? PostOutcome.shared : PostOutcome.queued;
    }
    await local.upsert(
      lead.copyWith(
        id: 'local-${DateTime.now().microsecondsSinceEpoch}',
        source: LeadSource.internal,
        createdAt: DateTime.now(),
      ),
    );
    return PostOutcome.deviceOnly;
  }

  /// Removes a lead from this device; a community lead the user posted is
  /// also deleted from Firestore. Dismissed scraped leads are remembered so
  /// the next refresh doesn't bring them back.
  Future<void> deleteLead(Lead lead) async {
    if (isSharedPost(lead)) {
      try {
        await community.deleteLead(lead.id);
      } catch (error) {
        // Already gone (removed elsewhere or by moderation): the rules
        // deny deleting a missing doc. Still drop the local copy.
        debugPrint('Remote delete of ${lead.id} failed: $error');
      }
    }
    if (lead.source == LeadSource.scraped) {
      await local.markRejected([lead.id]);
    }
    await local.delete(lead.id);
  }

  /// Whether deleting [lead] also removes it from Firestore for everyone.
  bool isSharedPost(Lead lead) =>
      lead.source == LeadSource.internal &&
      !lead.id.startsWith('local-') &&
      lead.authorId != null &&
      lead.authorId == community.currentUserId;

  /// Community leads can only be removed by their author.
  bool canDelete(Lead lead) =>
      lead.source != LeadSource.internal ||
      lead.id.startsWith('local-') ||
      (lead.authorId != null && lead.authorId == community.currentUserId);

  void _subscribeCommunity() {
    if (_disposed) {
      return;
    }
    _communitySub?.cancel();
    _community = const [];
    _communitySub = community
        .watchCommunityLeads(zipPrefix: profile.value?.zipPrefix)
        .listen((value) {
          _community = value;
          _publish();
        });
  }

  void _publish() {
    if (_disposed) {
      return;
    }
    final localById = {for (final lead in _local) lead.id: lead};
    final merged = <Lead>[
      for (final lead in _community)
        lead.copyWith(isFavorite: localById[lead.id]?.isFavorite ?? false),
    ];
    final communityIds = {for (final lead in _community) lead.id};
    merged.addAll(_local.where((lead) => !communityIds.contains(lead.id)));
    merged.sort((a, b) => b.sortTime.compareTo(a.sortTime));
    // Community orders and leads stored before grading existed get the
    // on-device grade; it is cheap, so it isn't cached.
    leads.value = List.unmodifiable([
      for (final lead in merged)
        lead.trust == null ? pipeline.grader.review(lead) : lead,
    ]);
  }

  static String _describe(Object error) {
    final text = error.toString();
    return text
        .replaceFirst('ListingFetchException: ', '')
        .replaceFirst('GeminiException: ', '');
  }
}
