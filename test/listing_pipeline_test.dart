import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:free_leads/config/app_config.dart';
import 'package:free_leads/models/lead.dart';
import 'package:free_leads/models/raw_listing.dart';
import 'package:free_leads/models/search_profile.dart';
import 'package:free_leads/sources/listing_source.dart';
import 'package:free_leads/sources/craigslist_source.dart';
import 'package:free_leads/services/gemini_service.dart';
import 'package:free_leads/sources/listing_fetch_service.dart';
import 'package:free_leads/sources/request_policy.dart';
import 'package:free_leads/services/listing_filter_service.dart';
import 'package:free_leads/services/listing_pipeline.dart';
import 'package:free_leads/services/local_listing_parser.dart';

import 'support/fakes.dart';

void main() {
  pipelineRunTests();

  test('profession filter expands trade synonyms', () {
    final gate = ListingFilterService.forProfession('Plumber');
    expect(gate.matches('Water heater is leaking'), isTrue);
    expect(gate.matches('Need help moving a couch'), isFalse);
  });

  test('keyword filter keeps service listings only', () {
    final filter = ListingFilterService();
    final kept = filter.filter([
      'Weekend BBQ at the park',
      'Need a plumber to fix a leak',
      'Random chat message',
    ]);
    expect(kept, ['Need a plumber to fix a leak']);
  });

  test('local parser extracts price, place, and category without Firebase', () {
    final lead = LocalListingParser().parse(
      'Need a plumber in Austin TX this evening. Around \$90.',
    );
    expect(lead.category, 'Plumbing');
    expect(lead.location, 'Austin TX');
    expect(lead.price, 90);
    expect(lead.source.name, 'parsed');
  });

  test(
    'pipeline skips unmatched text and structures matches in memory',
    () async {
      final pipeline = ListingPipeline();
      expect(await pipeline.structureIfRelevant('hello world'), isNull);
      final lead = await pipeline.structureIfRelevant(
        'Hiring a tutor in Seattle for algebra, \$45 an hour.',
      );
      expect(lead, isNotNull);
      expect(lead!.category, anyOf('Tutoring', 'Jobs'));
      expect(lead.price, 45);
    },
  );
}

/// Keeps the dated fixture posting inside the retention window.
const forever = Duration(days: 365 * 100);

/// A second site, to exercise the multi-source path.
class FakeSource extends ListingSource {
  FakeSource({this.hits = const [], this.error});

  final List<RawListing> hits;
  final Object? error;
  var closed = false;

  @override
  String get id => 'fakeboard';

  @override
  String get label => 'Fakeboard';

  @override
  String get idPrefix => 'fk-';

  @override
  HostStatus get status =>
      const HostStatus(requestsLastHour: 0, hourlyLimit: 10);

  @override
  Future<List<RawListing>> search(SearchProfile profile) async {
    if (error != null) {
      throw error!;
    }
    return hits;
  }

  @override
  Future<List<RawListing>> fetchDetails(List<RawListing> listings) async => [
    for (final listing in listings)
      listing.withDetails(
        body:
            'Leaking pipe under the kitchen sink, plumber needed Friday. '
            'Pay is firm.',
        compensation: r'$200',
        postedAt: DateTime.now(),
      ),
  ];

  @override
  void close() => closed = true;
}

RawListing fakeHit(String id, String title) => RawListing(
  id: id,
  url: Uri.parse('https://fakeboard.example/$id'),
  title: title,
  searchZip: '94110',
  board: 'fakeboard',
);

ListingPipeline fakePipeline({
  String apiKey = 'test-key',
  List<Uri>? log,
  http.Response Function(http.Request request)? gemini,
  List<ListingSource> extraSources = const [],
}) {
  final client = fakeInternet(log: log, gemini: gemini);
  return ListingPipeline(
    gemini: GeminiService(
      apiKey: apiKey,
      client: client,
      minRequestInterval: Duration.zero,
    ),
    sources: [
      CraigslistSource(
        fetcher: ListingFetchService(
          client: client,
          policy: RequestPolicy.unthrottled,
          maxAttempts: 1,
        ),
      ),
      ...extraSources,
    ],
    geocoder: testGeocoder(),
  );
}

const profile = SearchProfile(profession: 'plumber', zipCode: '94110');

void pipelineRunTests() {
  test(
    'run scrapes, de-spams with Gemini and returns structured leads',
    () async {
      final log = <Uri>[];
      final report = await fakePipeline(log: log).run(profile, maxAge: forever);

      expect(report.found, 3);
      expect(report.usedAi, isTrue);
      expect(report.warning, isNull);
      expect(report.rejectedIds, {'cl-ccc333'});
      expect(report.leads.map((lead) => lead.id), ['cl-aaa111', 'cl-bbb222']);

      final first = report.leads.first;
      expect(first.contactInfo, '510-555-0142');
      expect(first.postedAt, DateTime.utc(2026, 10, 14, 16, 15));
      // Placed by the posting's map point (Temescal), not the search ZIP;
      // the posting that failed to load keeps the search ZIP.
      expect(first.zipCode, '94609');
      expect(report.leads.last.zipCode, '94110');

      final searches = log.where((uri) => uri.path == '/search').toList();
      expect(searches.map((uri) => uri.queryParameters['cat']), [
        'ggg',
        'jjj',
      ], reason: 'gigs and jobs are both searched');
      expect(searches.first.queryParameters, {
        'cat': 'ggg',
        'postal': '94110',
        'radius': '25',
        'query': 'plumber',
      });
    },
  );

  test('every lead leaves graded, with its source and Gemini reason', () async {
    final report = await fakePipeline().run(profile, maxAge: forever);
    for (final lead in report.leads) {
      expect(lead.board, 'craigslist');
      expect(lead.trust, LeadTrust.reliable);
      expect(lead.trustByAi, isTrue);
      expect(lead.trustReasons, ['Clear scope and pay from a homeowner.']);
    }
  });

  test('searches all sources and de-duplicates cross-posts', () async {
    final extra = FakeSource(
      hits: [
        fakeHit('fk-1', 'Kitchen pipe leak'),
        // Same title as a Craigslist hit: a cross-post.
        fakeHit('fk-2', 'Repair leaking water heater'),
        // Wrong prefix: ignored, so ids can't collide across sources.
        fakeHit('cl-zzz', 'Spoofed id'),
      ],
    );
    final pipeline = fakePipeline(extraSources: [extra]);
    expect(pipeline.sourceNames, 'Craigslist and Fakeboard');

    final report = await pipeline.run(profile, maxAge: forever);
    expect(report.found, 5);
    final ids = report.leads.map((lead) => lead.id).toList();
    expect(ids, contains('fk-1'));
    expect(ids, isNot(contains('cl-zzz')));
    expect(
      report.leads.firstWhere((lead) => lead.id == 'fk-1').board,
      'fakeboard',
    );

    pipeline.close();
    expect(extra.closed, isTrue);
  });

  test('one failing source is a warning, all failing is an error', () async {
    final down = FakeSource(
      error: ListingFetchException('paused', failure: FetchFailure.coolingDown),
    );
    final report = await fakePipeline(extraSources: [down])
        .run(profile, maxAge: forever);
    expect(report.leads, isNotEmpty);
    expect(report.warning, contains("Fakeboard couldn't be searched: paused"));

    final onlyDown = ListingPipeline(
      gemini: GeminiService(apiKey: ''),
      sources: [down],
    );
    await expectLater(
      onlyDown.run(profile),
      throwsA(isA<ListingFetchException>()),
    );
  });

  test('run drops postings older than the retention window', () async {
    final judged = <String>[];
    final pipeline = fakePipeline(
      gemini: (request) {
        judged.addAll(promptListings(request).map((item) => item['id']));
        return judgeListings(request);
      },
    );
    // The fixture posting (cl-aaa111) is dated 2026-10-14.
    final report = await pipeline.run(
      profile,
      maxAge: DateTime.now().difference(DateTime.utc(2026, 10, 1)),
    );
    expect(report.tooOld, 0);

    final strict = await pipeline.run(profile, maxAge: Duration.zero);
    expect(strict.tooOld, 1);
    expect(strict.rejectedIds, contains('cl-aaa111'));
    expect(strict.leads.map((lead) => lead.id), isNot(contains('cl-aaa111')));
    expect(judged.where((id) => id == 'cl-aaa111'), hasLength(1));
  });

  test('run skips listings already stored or rejected', () async {
    final log = <Uri>[];
    final report = await fakePipeline(log: log).run(
      profile,
      knownIds: {'cl-aaa111'},
      rejectedIds: {'cl-ccc333'},
      maxAge: forever,
    );
    expect(report.alreadyKnown, 2);
    expect(report.leads.map((lead) => lead.id), ['cl-bbb222']);
    expect(log.where((uri) => uri.path.contains('/view/')), hasLength(1));
  });

  test(
    'stored leads at the search ZIP are reread for their real one',
    () async {
      Lead stored(String id, {String? url}) => Lead(
        id: id,
        title: 'Old post',
        description: '',
        category: 'Plumbing',
        location: 'Oakland',
        zipCode: profile.zipCode,
        sourceUrl: url,
      );
      final saved = [
        stored('cl-aaa111', url: 'https://sfbay.craigslist.org/d/x/aaa111'),
        stored('cl-bbb222', url: 'https://sfbay.craigslist.org/d/x/bbb222'),
        // No longer in the search results, but its page still opens.
        stored('cl-gone', url: 'https://sfbay.craigslist.org/d/y/aaa111'),
        stored('cl-nolink'),
        stored('xx-other', url: 'https://example.com/post/1'),
      ];
      final log = <Uri>[];
      final report = await fakePipeline(log: log).run(
        profile,
        knownIds: {'cl-aaa111', 'cl-bbb222'},
        rejectedIds: {'cl-ccc333'},
        relocate: saved,
        maxAge: forever,
      );
      expect(report.leads, isEmpty);
      expect(report.alreadyKnown, 3);
      // bbb222's page fails to load: checked, but nothing better found.
      // Leads without a link, or from a board that isn't searched, can't
      // be reread.
      expect(report.relocated, {
        'cl-aaa111': '94609',
        'cl-bbb222': null,
        'cl-gone': '94609',
      });
      expect(log.where((uri) => uri.path.contains('/d/')), hasLength(3));

      final capped = await fakePipeline().run(
        profile,
        knownIds: {'cl-aaa111', 'cl-bbb222', 'cl-ccc333'},
        relocate: saved,
        maxRelocate: 1,
        maxAge: forever,
      );
      expect(capped.relocated.keys, ['cl-aaa111']);

      final none = await fakePipeline(log: log..clear()).run(
        profile,
        knownIds: {'cl-aaa111', 'cl-bbb222', 'cl-ccc333'},
        maxAge: forever,
      );
      expect(none.relocated, isEmpty);
      expect(log.where((uri) => uri.path.contains('/view/')), isEmpty);
    },
  );

  test(
    'without a Gemini key, falls back to keyword gate + local parser',
    () async {
      final report = await fakePipeline(apiKey: '')
          .run(profile, maxAge: forever);
      expect(report.usedAi, isFalse);
      expect(report.warning, isNull, reason: 'the feed has its own notice');
      expect(report.leads.map((lead) => lead.id), ['cl-aaa111', 'cl-bbb222']);
      expect(report.leads.first.contactInfo, '510-555-0142');
      expect(report.leads.first.budget, r'$85/hr');
      expect(report.leads.last.price, 1200);
    },
    skip: AppConfig.hasGeminiKey
        ? 'GEMINI_API_KEY is set in this environment'
        : false,
  );
}
