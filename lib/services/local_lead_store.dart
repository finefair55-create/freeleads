import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import '../models/lead.dart';
import '../models/search_profile.dart';
import '../sources/request_policy.dart';

/// On-device persistence (Hive) for offline access and favorites.
///
/// Leads are stored as JSON strings keyed by lead id, which keeps the schema
/// in [Lead.toJson]/[Lead.fromJson] and needs no generated adapters.
class LocalLeadStore implements HostBackoffStore {
  LocalLeadStore._(this._leads, this._rejected, this._settings);

  static const _leadsBox = 'leads_v1';
  static const _rejectedBox = 'rejected_listings_v1';
  static const _settingsBox = 'settings_v1';

  static const _profileKey = 'searchProfile';
  static const _geminiKeyKey = 'geminiApiKey';
  static const _lastRefreshKey = 'lastRefresh';
  static const _hideSpamKey = 'hideSpam';
  static const _cooldownPrefix = 'cooldown:';
  static const _strikesPrefix = 'strikes:';
  static const _themeModeKey = 'themeMode';
  static const _aiNoticeKey = 'aiNoticeDismissed';

  /// Caps that keep the boxes small however long the app is used.
  static const maxStoredLeads = 400;
  static const maxRejectedIds = 3000;

  final Box<String> _leads;
  final Box<String> _rejected;
  final Box<dynamic> _settings;

  /// Opens the boxes. Pass [path] in tests or on platforms without
  /// path_provider; otherwise the app documents directory is used.
  static Future<LocalLeadStore> open({String? path}) async {
    if (path != null) {
      Hive.init(path);
    } else {
      await Hive.initFlutter('free_leads');
    }
    final boxes = await Future.wait([
      Hive.openBox<String>(_leadsBox),
      Hive.openBox<String>(_rejectedBox),
      Hive.openBox<dynamic>(_settingsBox),
    ]);
    return LocalLeadStore._(
      boxes[0] as Box<String>,
      boxes[1] as Box<String>,
      boxes[2],
    );
  }

  // ---- Leads -------------------------------------------------------------

  List<Lead> get all {
    final leads = <Lead>[];
    for (final key in _leads.keys) {
      final lead = _decode(key as String, _leads.get(key));
      if (lead != null) {
        leads.add(lead);
      }
    }
    leads.sort((a, b) => b.sortTime.compareTo(a.sortTime));
    return leads;
  }

  Lead? get(String id) => _decode(id, _leads.get(id));

  bool contains(String id) => _leads.containsKey(id);

  Set<String> get ids => _leads.keys.cast<String>().toSet();

  /// Emits the current list, then again whenever the box changes. Bursts of
  /// writes (e.g. [upsertAll]) are coalesced into one emission.
  Stream<List<Lead>> watch() {
    late final StreamController<List<Lead>> controller;
    StreamSubscription<BoxEvent>? subscription;
    var scheduled = false;
    void emit() {
      if (scheduled) {
        return;
      }
      scheduled = true;
      scheduleMicrotask(() {
        scheduled = false;
        if (!controller.isClosed) {
          controller.add(all);
        }
      });
    }

    controller = StreamController<List<Lead>>(
      onListen: () {
        controller.add(all);
        subscription = _leads.watch().listen((_) => emit());
      },
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  Future<void> upsert(Lead lead) => upsertAll([lead]);

  /// Saves [leads], preserving the favorite flag of any already stored copy.
  Future<void> upsertAll(Iterable<Lead> leads) async {
    final entries = <String, String>{};
    for (final lead in leads) {
      if (lead.id.isEmpty) {
        continue;
      }
      final existing = get(lead.id);
      final merged = existing?.isFavorite == true && !lead.isFavorite
          ? lead.copyWith(isFavorite: true)
          : lead;
      entries[lead.id] = jsonEncode(merged.toJson());
    }
    if (entries.isNotEmpty) {
      await _leads.putAll(entries);
    }
  }

  /// Stores [lead] (if needed) with the favorite flag set to [favorite].
  Future<void> setFavorite(Lead lead, bool favorite) async {
    final stored = get(lead.id) ?? lead;
    await _leads.put(
      lead.id,
      jsonEncode(stored.copyWith(isFavorite: favorite).toJson()),
    );
  }

  Future<void> delete(String id) => _leads.delete(id);

  /// Garbage-collects the boxes:
  ///
  /// * scraped and imported leads older than [maxAge], unless saved;
  /// * other people's community orders older than [maxAge] that are kept
  ///   only as a local copy (requires [myUid], so the user's own orders and
  ///   device-only posts are never dropped);
  /// * the oldest unsaved scraped leads beyond [maxLeads];
  /// * rejected ids older than [maxAge], and the oldest beyond
  ///   [maxRejected].
  ///
  /// Returns the number of leads removed.
  Future<int> prune(
    Duration maxAge, {
    String? myUid,
    int maxLeads = maxStoredLeads,
    int maxRejected = maxRejectedIds,
  }) async {
    final cutoff = DateTime.now().subtract(maxAge);
    final stale = <String>[];
    final keptScraped = <Lead>[];
    for (final lead in all) {
      if (lead.isFavorite) {
        continue;
      }
      final old = lead.sortTime.isBefore(cutoff);
      if (lead.source != LeadSource.internal) {
        if (old) {
          stale.add(lead.id);
        } else {
          keptScraped.add(lead);
        }
      } else if (old &&
          myUid != null &&
          lead.authorId != null &&
          lead.authorId != myUid) {
        stale.add(lead.id);
      }
    }
    // [all] is newest first, so the overflow is at the end.
    if (keptScraped.length > maxLeads) {
      stale.addAll(keptScraped.skip(maxLeads).map((lead) => lead.id));
    }
    if (stale.isNotEmpty) {
      await _leads.deleteAll(stale);
    }

    final rejected = <(String, DateTime)>[];
    final staleRejected = <String>[];
    for (final key in _rejected.keys) {
      final at = DateTime.tryParse(_rejected.get(key) ?? '');
      if (at == null || at.isBefore(cutoff)) {
        staleRejected.add(key as String);
      } else {
        rejected.add((key as String, at));
      }
    }
    if (rejected.length > maxRejected) {
      rejected.sort((a, b) => b.$2.compareTo(a.$2));
      staleRejected.addAll(rejected.skip(maxRejected).map((entry) => entry.$1));
    }
    if (staleRejected.isNotEmpty) {
      await _rejected.deleteAll(staleRejected);
    }
    return stale.length;
  }

  /// Rewrites the box files without deleted entries. Hive also does this
  /// on its own once enough entries are deleted.
  Future<void> compact() async {
    await Future.wait([_leads.compact(), _rejected.compact()]);
  }

  // ---- Rejected listings -------------------------------------------------

  Set<String> get rejectedIds => _rejected.keys.cast<String>().toSet();

  Future<void> markRejected(Iterable<String> ids) async {
    final now = DateTime.now().toIso8601String();
    await _rejected.putAll({for (final id in ids) id: now});
  }

  Future<void> clearRejected() => _rejected.clear();

  // ---- Settings ----------------------------------------------------------

  SearchProfile? get searchProfile {
    final raw = _settings.get(_profileKey);
    if (raw is! String) {
      return null;
    }
    try {
      return SearchProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (error) {
      debugPrint('Ignoring unreadable search profile: $error');
      return null;
    }
  }

  Future<void> saveSearchProfile(SearchProfile profile) =>
      _settings.put(_profileKey, jsonEncode(profile.toJson()));

  /// A Gemini key the user entered in the app. Stored in the app sandbox;
  /// move to platform secure storage if your threat model needs it.
  String? get geminiApiKey => _settings.get(_geminiKeyKey) as String?;

  Future<void> saveGeminiApiKey(String? key) {
    final trimmed = key?.trim() ?? '';
    return trimmed.isEmpty
        ? _settings.delete(_geminiKeyKey)
        : _settings.put(_geminiKeyKey, trimmed);
  }

  /// Whether "Possible spam" leads are hidden from the feed and map.
  bool get hideSpam => _settings.get(_hideSpamKey) == true;

  Future<void> saveHideSpam(bool value) => _settings.put(_hideSpamKey, value);

  @override
  DateTime? cooldownUntil(String host) => DateTime.tryParse(
    _settings.get('$_cooldownPrefix$host') as String? ?? '',
  );

  @override
  Future<void> saveCooldown(String host, DateTime? until) => until == null
      ? _settings.delete('$_cooldownPrefix$host')
      : _settings.put('$_cooldownPrefix$host', until.toIso8601String());

  @override
  int strikes(String host) =>
      (_settings.get('$_strikesPrefix$host') as num?)?.toInt() ?? 0;

  @override
  Future<void> saveStrikes(String host, int strikes) => strikes <= 0
      ? _settings.delete('$_strikesPrefix$host')
      : _settings.put('$_strikesPrefix$host', strikes);

  /// Whether the feed's "AI filter is off" notice was closed.
  bool get aiNoticeDismissed => _settings.get(_aiNoticeKey) == true;

  Future<void> saveAiNoticeDismissed(bool value) =>
      _settings.put(_aiNoticeKey, value);

  /// `light`, `dark`, or null to follow the system.
  String? get themeMode => _settings.get(_themeModeKey) as String?;

  Future<void> saveThemeMode(String? mode) => mode == null
      ? _settings.delete(_themeModeKey)
      : _settings.put(_themeModeKey, mode);

  DateTime? get lastRefresh =>
      DateTime.tryParse(_settings.get(_lastRefreshKey) as String? ?? '');

  Future<void> saveLastRefresh(DateTime time) =>
      _settings.put(_lastRefreshKey, time.toIso8601String());

  Future<void> close() async {
    await Future.wait([_leads.close(), _rejected.close(), _settings.close()]);
  }

  static Lead? _decode(String id, String? raw) {
    if (raw == null) {
      return null;
    }
    try {
      return Lead.fromJson(jsonDecode(raw) as Map<String, dynamic>, id: id);
    } catch (error) {
      debugPrint('Skipping corrupt lead $id: $error');
      return null;
    }
  }
}
