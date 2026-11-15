import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../config/app_config.dart';
import '../models/lead.dart';
import '../models/raw_listing.dart';
import '../models/search_profile.dart';
import '../sources/craigslist_source.dart';
import '../sources/listing_fetch_service.dart';
import '../sources/listing_source.dart';
import '../sources/request_policy.dart';
import 'gemini_service.dart';
import 'lead_grader.dart';
import 'listing_filter_service.dart';
import 'local_listing_parser.dart';
import 'zip_geocoder.dart';

/// Result of one scrape → clean → structure run.
class PipelineReport {
  const PipelineReport({
    required this.leads,
    required this.rejectedIds,
    required this.found,
    required this.alreadyKnown,
    required this.usedAi,
    this.tooOld = 0,
    this.relocated = const {},
    this.warning,
  });

  final List<Lead> leads;
  final Set<String> rejectedIds;

  /// Search hits across all sources before de-duplication.
  final int found;

  /// Hits skipped because they were stored or rejected on an earlier run.
  final int alreadyKnown;

  /// Postings older than the retention window. They are included in
  /// [rejectedIds] so they aren't fetched again, but weren't sent to Gemini.
  final int tooOld;

  /// Stored leads rechecked for their real location (see `relocate` on
  /// [ListingPipeline.run]): id → the posting's ZIP, or null when the
  /// posting gave no usable location.
  final Map<String, String?> relocated;

  /// Whether Gemini judged at least part of this run.
  final bool usedAi;

  /// Non-fatal problems to show the user (e.g. Gemini quota reached, one
  /// source paused).
  final String? warning;
}

/// Searches every [ListingSource] on-device, drops what we've already
/// seen, then lets Gemini clean, de-spam, structure and grade the rest.
/// Without a Gemini key (or when its quota is exhausted) a keyword gate and
/// [LocalListingParser] take over. Every lead leaves sanitized and graded.
class ListingPipeline {
  ListingPipeline({
    ListingFilterService? filter,
    GeminiService? gemini,
    List<ListingSource>? sources,
    LocalListingParser? localParser,
    ZipGeocoder? geocoder,
    this.grader = const LeadGrader(),
  }) : filter = filter ?? ListingFilterService(),
       geocoder = geocoder ?? ZipGeocoder.instance,
       gemini = gemini ?? GeminiService(),
       sources = List.unmodifiable(sources ?? defaultSources()),
       _localParser = localParser ?? LocalListingParser();

  /// The sources searched by default. Add new sites here.
  static List<ListingSource> defaultSources({HostCooldownStore? cooldowns}) => [
    CraigslistSource(cooldowns: cooldowns),
  ];

  final ListingFilterService filter;
  final GeminiService gemini;
  final List<ListingSource> sources;
  final LeadGrader grader;

  /// Turns a posting's map point into the ZIP it lies in.
  final ZipGeocoder geocoder;
  final LocalListingParser _localParser;

  List<ListingSource> get activeSources =>
      sources.where((source) => source.isSupported).toList(growable: false);

  /// "Craigslist" or "Craigslist and Example", for status messages.
  String get sourceNames {
    final names = activeSources.map((source) => source.label).toList();
    if (names.length <= 1) {
      return names.isEmpty ? 'listing sites' : names.single;
    }
    return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }

  /// Sanitizes and grades a lead from outside the scrape (an import, a
  /// community order).
  Lead finalize(Lead lead) => grader.review(lead.sanitized());

  List<String> keepRelevant(Iterable<String> rawListings) =>
      filter.filter(rawListings);

  Future<Lead?> structureIfRelevant(String rawText) async {
    if (!filter.matches(rawText)) {
      return null;
    }
    final lead = await gemini.structureListing(rawText);
    return lead == null ? null : finalize(lead);
  }

  /// One scrape. Hits in [knownIds] or [rejectedIds] are skipped. Up to
  /// [maxRelocate] of the stored leads in [relocate] (ones still placed at
  /// the search ZIP) also have their posting reread, whether or not the
  /// search still lists them, to find where they really are; see
  /// [PipelineReport.relocated].
  Future<PipelineReport> run(
    SearchProfile profile, {
    Set<String> knownIds = const {},
    Set<String> rejectedIds = const {},
    Iterable<Lead> relocate = const [],
    int maxRelocate = 40,
    int maxNew = AppConfig.maxListingsPerRefresh,
    Duration maxAge = AppConfig.scrapedLeadRetention,
    void Function(String message)? onProgress,
  }) async {
    final active = activeSources;
    if (active.isEmpty) {
      throw ListingFetchException(
        'Scraping runs on the mobile and desktop apps only, not in a browser.',
        failure: FetchFailure.unsupported,
      );
    }

    // Different hosts, so sources are searched in parallel; each keeps its
    // own rate limit.
    final searches = await Future.wait([
      for (final source in active) _search(source, profile),
    ]);
    final failures = [
      for (final result in searches)
        if (result.error != null) result,
    ];
    if (failures.length == searches.length) {
      // Nothing worked; let the caller tell offline from blocked.
      Error.throwWithStackTrace(failures.first.error!, failures.first.stack!);
    }
    final warnings = <String>[
      for (final failure in failures)
        "${failure.source.label} couldn't be searched: "
            '${_describe(failure.error!)}',
    ];

    // Interleave sources so a busy board can't use up the whole [maxNew]
    // budget and starve the others.
    final hits = _interleave([for (final result in searches) result.hits]);
    final fresh = <RawListing>[];
    final seenIds = <String>{};
    final seenTitles = <String>{};
    var alreadyKnown = 0;
    for (final hit in hits) {
      if (knownIds.contains(hit.id) || rejectedIds.contains(hit.id)) {
        alreadyKnown++;
        continue;
      }
      // Reposts (and cross-posts to several sites) often reuse the title
      // under a new id.
      final titleText = hit.title.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      // A title with no Latin letters or digits says nothing about
      // duplicates; collapsing all of them would drop unrelated posts.
      final titleKey = titleText.isEmpty
          ? null
          : '$titleText|${hit.neighborhood?.toLowerCase() ?? ''}';
      if (seenIds.add(hit.id) &&
          (titleKey == null || seenTitles.add(titleKey))) {
        fresh.add(hit);
      }
    }
    final reread = _postingsOf(relocate, profile, active, maxRelocate);
    String? warning() => warnings.isEmpty ? null : warnings.join(' ');
    if (fresh.isEmpty && reread.isEmpty) {
      return PipelineReport(
        leads: const [],
        rejectedIds: const {},
        found: hits.length,
        alreadyKnown: alreadyKnown,
        usedAi: false,
        warning: warning(),
      );
    }

    final batch = fresh.take(maxNew).toList(growable: false);
    if (batch.isNotEmpty) {
      onProgress?.call('Reading ${batch.length} new posting(s)…');
    } else {
      onProgress?.call('Placing ${reread.length} saved lead(s) on the map…');
    }
    final located = await _locate(
      await _fetchDetails([...batch, ...reread.values], active),
    );
    final relocated = <String, String?>{
      for (final listing in located)
        if (reread.containsKey(listing.id))
          listing.id: Lead.normalizeZip(listing.zipCode),
    };
    final fetched = [
      for (final listing in located)
        if (!reread.containsKey(listing.id)) listing,
    ];

    // Search results include old postings, and the store prunes anything
    // past the retention window, so don't spend Gemini quota on them.
    final cutoff = DateTime.now().subtract(maxAge);
    final stale = {
      for (final listing in fetched)
        if (listing.postedAt?.isBefore(cutoff) ?? false) listing.id,
    };
    final detailed = [
      for (final listing in fetched)
        if (!stale.contains(listing.id)) listing,
    ];

    var leads = <Lead>[];
    final rejected = <String>{...stale};
    var remaining = detailed;
    var usedAi = false;

    if (detailed.isEmpty) {
      // Everything new was too old; nothing to structure.
    } else if (gemini.isConfigured) {
      onProgress?.call('Gemini is reviewing ${detailed.length} listing(s)…');
      StructuringResult result;
      try {
        result = await gemini.structureBatch(
          detailed,
          profession: profile.profession,
        );
      } catch (error) {
        // Never lose a run's listings to an AI failure; grade them locally.
        debugPrint('Gemini review failed: $error');
        result = StructuringResult(
          kept: const [],
          rejectedIds: const {},
          unprocessed: detailed,
          error: error is GeminiException
              ? error
              : GeminiException('Gemini review failed.'),
        );
      }
      usedAi = result.unprocessed.length < detailed.length;
      leads = List.of(result.kept);
      rejected.addAll(result.rejectedIds);
      remaining = result.unprocessed;
      if (result.error != null) {
        warnings.add(
          '${result.error!.message} '
          '${remaining.length} listing(s) used basic keyword filtering.',
        );
      }
    }

    if (remaining.isNotEmpty) {
      leads.addAll(_structureLocally(remaining, profile));
    }

    return PipelineReport(
      leads: [for (final lead in leads) finalize(lead)],
      rejectedIds: rejected,
      found: hits.length,
      alreadyKnown: alreadyKnown,
      usedAi: usedAi,
      tooOld: stale.length,
      relocated: relocated,
      warning: warning(),
    );
  }

  /// Postings to reread for [leads]' locations: at most [max], and only
  /// leads with a link that one of the [active] sources can read.
  static Map<String, RawListing> _postingsOf(
    Iterable<Lead> leads,
    SearchProfile profile,
    List<ListingSource> active,
    int max,
  ) {
    final postings = <String, RawListing>{};
    for (final lead in leads) {
      if (postings.length >= max) {
        break;
      }
      final url = Uri.tryParse(lead.sourceUrl ?? '');
      if (url == null ||
          !url.hasScheme ||
          !active.any((source) => lead.id.startsWith(source.idPrefix))) {
        continue;
      }
      postings[lead.id] = RawListing(
        id: lead.id,
        url: url,
        title: lead.title,
        searchZip: profile.zipCode,
      );
    }
    return postings;
  }

  /// Fills in the ZIP of listings that state none but carry a map point,
  /// so each lead is pinned in its own town rather than at the search's
  /// center. Without the ZIP table, listings are returned as they are.
  Future<List<RawListing>> _locate(List<RawListing> listings) async {
    bool needsZip(RawListing listing) =>
        Lead.normalizeZip(listing.zipCode) == null &&
        listing.latitude != null &&
        listing.longitude != null;
    if (!listings.any(needsZip)) {
      return listings;
    }
    try {
      await geocoder.ensureLoaded();
    } catch (error) {
      debugPrint('ZIP table unavailable: $error');
      return listings;
    }
    return [
      for (final listing in listings)
        if (needsZip(listing))
          listing.withDetails(
            zipCode: geocoder.nearestZip(
              LatLng(listing.latitude!, listing.longitude!),
            ),
          )
        else
          listing,
    ];
  }

  Future<_SearchResult> _search(
    ListingSource source,
    SearchProfile profile,
  ) async {
    try {
      final hits = await source.search(profile);
      return _SearchResult(source, [
        // Guard against a source handing out another source's ids.
        for (final hit in hits)
          if (hit.id.startsWith(source.idPrefix)) hit,
      ]);
    } catch (error, stack) {
      return _SearchResult(source, const [], error, stack);
    }
  }

  /// Fetches details per source, in parallel across sources, keeping the
  /// original order.
  Future<List<RawListing>> _fetchDetails(
    List<RawListing> listings,
    List<ListingSource> active,
  ) async {
    ListingSource? owner(RawListing listing) {
      for (final source in active) {
        if (listing.id.startsWith(source.idPrefix)) {
          return source;
        }
      }
      return null;
    }

    final bySource = <ListingSource, List<RawListing>>{};
    for (final listing in listings) {
      final source = owner(listing);
      if (source != null) {
        bySource.putIfAbsent(source, () => []).add(listing);
      }
    }
    final details = <String, RawListing>{};
    await Future.wait([
      for (final MapEntry(key: source, value: group) in bySource.entries)
        source
            .fetchDetails(group)
            .then(
              (filled) => filled,
              // One source failing must not sink the others' results; keep
              // its summary fields so the hits are still reviewed.
              onError: (Object error) {
                debugPrint('${source.label} details failed: $error');
                return group;
              },
            )
            .then((filled) {
              for (final listing in filled) {
                details[listing.id] = listing;
              }
            }),
    ]);
    return [
      for (final listing in listings)
        if (details[listing.id] != null) details[listing.id]!,
    ];
  }

  static List<RawListing> _interleave(List<List<RawListing>> lists) {
    final merged = <RawListing>[];
    for (var i = 0; lists.any((list) => i < list.length); i++) {
      for (final list in lists) {
        if (i < list.length) {
          merged.add(list[i]);
        }
      }
    }
    return merged;
  }

  List<Lead> _structureLocally(
    List<RawListing> listings,
    SearchProfile profile,
  ) {
    final gate = ListingFilterService.forProfession(profile.profession);
    final now = DateTime.now();
    final leads = <Lead>[];
    for (final listing in listings) {
      final text = listing.toPromptText();
      if (!gate.matches(text)) {
        continue;
      }
      final parsed = _localParser.parse(text);
      final budget = listing.compensation ?? listing.priceText;
      leads.add(
        parsed.copyWith(
          id: listing.id,
          title: listing.title,
          description: listing.body ?? listing.title,
          location: listing.neighborhood ?? parsed.location,
          // Without AI we can't tell a ZIP from e.g. "$12000" in the body;
          // use the ZIP the board states, else the search center.
          zipCode: listing.zipCode ?? listing.searchZip,
          price: Lead.parsePrice(budget) ?? parsed.price,
          budget: budget,
          contactInfo: _contactFrom(listing.body),
          sourceUrl: listing.url.toString(),
          source: LeadSource.scraped,
          board: listing.board,
          createdAt: now,
          postedAt: listing.postedAt,
        ),
      );
    }
    return leads;
  }

  /// Closes every source's and Gemini's HTTP connections.
  void close() {
    for (final source in sources) {
      source.close();
    }
    gemini.close();
  }

  static String _describe(Object error) => error
      .toString()
      .replaceFirst('ListingFetchException: ', '')
      .replaceFirst('GeminiException: ', '');

  static String? _contactFrom(String? body) {
    if (body == null) {
      return null;
    }
    final email = RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+')
        .firstMatch(body)
        ?.group(0);
    final phone = RegExp(r'(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}')
        .firstMatch(body)
        ?.group(0);
    final parts = [?phone, ?email];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

class _SearchResult {
  const _SearchResult(this.source, this.hits, [this.error, this.stack]);

  final ListingSource source;
  final List<RawListing> hits;
  final Object? error;
  final StackTrace? stack;
}
