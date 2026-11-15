import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_leads/models/lead.dart';
import 'package:free_leads/models/raw_listing.dart';
import 'package:free_leads/models/search_profile.dart';
import 'package:free_leads/services/gemini_service.dart';
import 'package:free_leads/services/lead_repository.dart';
import 'package:free_leads/services/listing_pipeline.dart';
import 'package:free_leads/services/local_lead_store.dart';
import 'package:free_leads/theme/app_theme.dart';
import 'package:free_leads/widgets/lead_card.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'lead_repository_test.dart' show FakeCommunity;
import 'listing_pipeline_test.dart' show FakeSource, fakeHit, forever, profile;

/// A [FakeSource] whose posting pages can't be read at all.
class _BrokenDetailsSource extends FakeSource {
  _BrokenDetailsSource({super.hits});

  @override
  String get id => 'broken';

  @override
  String get idPrefix => 'bk-';

  @override
  Future<List<RawListing>> fetchDetails(List<RawListing> listings) =>
      Future.error(StateError('parser crashed'));
}

/// Returns one plumbing hit per searched ZIP, once that ZIP's gate opens.
class _GatedSource extends FakeSource {
  _GatedSource(this.gates);

  final Map<String, Future<void>> gates;

  @override
  String get id => 'gated';

  @override
  String get idPrefix => 'gt-';

  @override
  Future<List<RawListing>> search(SearchProfile profile) async {
    await gates[profile.zipCode];
    return [
      RawListing(
        id: 'gt-${profile.zipCode}',
        url: Uri.parse('https://gated.example/${profile.zipCode}'),
        title: 'Plumber needed for a leaking pipe',
        searchZip: profile.zipCode,
        board: 'gated',
      ),
    ];
  }
}

void main() {
  test(
    'one source failing to read details keeps every source\'s leads',
    () async {
      final pipeline = ListingPipeline(
        gemini: GeminiService(apiKey: ''),
        sources: [
          _BrokenDetailsSource(
            hits: [
              RawListing(
                id: 'bk-1',
                url: Uri.parse('https://broken.example/1'),
                title: 'Plumber wanted: leaking toilet',
                searchZip: '94110',
                board: 'broken',
              ),
            ],
          ),
          FakeSource(hits: [fakeHit('fk-1', 'Kitchen pipe leak')]),
        ],
      );
      final report = await pipeline.run(profile, maxAge: forever);
      expect(
        report.leads.map((lead) => lead.id),
        unorderedEquals(['bk-1', 'fk-1']),
      );
    },
  );

  test(
    'an unreadable 200 from Gemini falls back instead of throwing',
    () async {
      final gemini = GeminiService(
        apiKey: 'test-key',
        client: MockClient(
          (_) async => http.Response('<html>Sign in to Wi-Fi</html>', 200),
        ),
        minRequestInterval: Duration.zero,
      );
      final listing = fakeHit('fk-1', 'Kitchen pipe leak');
      final result = await gemini.structureBatch([
        listing,
      ], profession: 'plumber');
      expect(result.error, isA<GeminiException>());
      expect(result.unprocessed, [listing]);
    },
  );

  group('repository', () {
    late Directory dir;
    late LocalLeadStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('free_leads_audit_');
      store = await LocalLeadStore.open(path: dir.path);
    });

    tearDown(() async {
      await Hive.deleteFromDisk();
      await dir.delete(recursive: true);
    });

    test('changing the profile mid-search discards the old results', () async {
      final oldSearch = Completer<void>();
      final repository = LeadRepository(
        local: store,
        community: FakeCommunity(),
        pipeline: ListingPipeline(
          gemini: GeminiService(apiKey: ''),
          sources: [
            _GatedSource({'10001': oldSearch.future}),
          ],
        ),
        autoRefreshInterval: null,
      )..start();
      addTearDown(repository.dispose);
      repository.profile.value = const SearchProfile(
        profession: 'plumber',
        zipCode: '10001',
      );

      final stale = repository.refresh();
      await Future<void>.delayed(Duration.zero);
      final update = repository.updateProfile(
        const SearchProfile(profession: 'plumber', zipCode: '94110'),
      );
      // Let the update reach its own search before the stale one lands.
      // Without the fix it joined the stale run and stored its results.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      oldSearch.complete();
      await stale;
      await update;

      expect(store.ids, {'gt-94110'});
      expect(repository.status.value.phase, RefreshPhase.succeeded);
    });

    test(
      'switching trade mid-search clears the old leads right away',
      () async {
        final oldSearch = Completer<void>();
        final repository = LeadRepository(
          local: store,
          community: FakeCommunity(),
          pipeline: ListingPipeline(
            gemini: GeminiService(apiKey: ''),
            sources: [
              _GatedSource({'10001': oldSearch.future}),
            ],
          ),
          autoRefreshInterval: null,
        )..start();
        addTearDown(repository.dispose);
        await store.upsert(
          const Lead(
            id: 'gt-old',
            title: 'Fix a leaking pipe',
            description: 'Kitchen sink.',
            category: 'Plumbing',
            location: 'Chelsea',
            source: LeadSource.scraped,
          ),
        );
        repository.profile.value = const SearchProfile(
          profession: 'plumber',
          zipCode: '10001',
        );

        final stale = repository.refresh();
        await Future<void>.delayed(Duration.zero);
        final update = repository.switchTrade('electrician');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // Gone while the plumber search is still out, not after it lands.
        expect(store.ids, isNot(contains('gt-old')));
        expect(repository.status.value.isRunning, isTrue);
        expect(repository.status.value.message, contains('10001'));

        oldSearch.complete();
        await stale;
        await update;
        expect(repository.profile.value?.profession, 'electrician');
        expect(repository.status.value.phase, RefreshPhase.succeeded);
        expect(store.ids, isEmpty, reason: 'plumbing hit filtered out');
      },
    );
  });

  group('lead card fits a phone', () {
    final lead = Lead(
      id: 'cl-1',
      title:
          'Need an experienced plumber to replace a water heater and '
          'reroute pipes in the basement',
      description: 'Old 40 gallon tank, gas line already in place. ' * 6,
      category: 'Appliance Repair',
      location: 'South Philadelphia',
      zipCode: '19103',
      budget: r'$40/hr negotiable depending on experience',
      contactInfo: '215-555-0100',
      source: LeadSource.scraped,
      board: 'craigslist',
      trust: LeadTrust.questionable,
      postedAt: DateTime.now().subtract(const Duration(days: 3)),
    );

    for (final width in [280.0, 320.0]) {
      for (final scale in [1.0, 1.6]) {
        testWidgets('at ${width.round()}px, ${scale}x text', (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.light(),
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: width,
                      // The grid's card height at 1x text, which larger
                      // text gets more of.
                      height: 270,
                      child: LeadCard(lead: lead, onFavorite: () {}),
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
          expect(find.text('Questionable'), findsOneWidget);
        });
      }
    }
  });
}
