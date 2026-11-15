import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_leads/app.dart';
import 'package:free_leads/config/app_config.dart';
import 'package:free_leads/models/lead.dart';
import 'package:free_leads/models/search_profile.dart';
import 'package:free_leads/screens/home_screen.dart';
import 'package:free_leads/screens/profile_screen.dart';
import 'package:free_leads/services/firestore_service.dart';
import 'package:free_leads/services/gemini_service.dart';
import 'package:free_leads/services/lead_repository.dart';
import 'package:free_leads/services/listing_pipeline.dart';
import 'package:free_leads/services/local_lead_store.dart';
import 'package:free_leads/sources/craigslist_source.dart';
import 'package:free_leads/sources/listing_fetch_service.dart';
import 'package:free_leads/sources/request_policy.dart';
import 'package:free_leads/widgets/lead_badges.dart';
import 'package:free_leads/widgets/lead_card.dart';
import 'package:free_leads/widgets/search_profile_bar.dart';
import 'package:free_leads/widgets/feed_notices.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fakes.dart';

void main() {
  late Directory dir;
  late LocalLeadStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('free_leads_ui_');
    store = await LocalLeadStore.open(path: dir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  Future<LeadRepository> pumpApp(
    WidgetTester tester, {
    http.Client? client,
  }) async {
    await tester.runAsync(
      () => store.saveSearchProfile(
        const SearchProfile(profession: 'plumber', zipCode: '10001'),
      ),
    );
    client ??= fakeInternet();
    final repository = LeadRepository(
      local: store,
      community: FirestoreService.unavailable(),
      pipeline: ListingPipeline(
        gemini: GeminiService(apiKey: '', client: client),
        sources: [
          CraigslistSource(
            fetcher: ListingFetchService(
              client: client,
              policy: RequestPolicy.unthrottled,
              maxAttempts: 1,
            ),
          ),
        ],
        geocoder: testGeocoder(),
      ),
      autoRefreshInterval: null,
    )..start();
    addTearDown(repository.dispose);
    await tester.pumpWidget(FreeLeadsApp(repository: repository));
    await tester.pump();
    return repository;
  }

  Lead lead(String id, String board) => Lead(
    id: id,
    title: 'Job $id',
    description: 'Details',
    category: 'Plumbing',
    location: 'Chelsea',
    zipCode: '10001',
    source: LeadSource.scraped,
    board: board,
    createdAt: DateTime.now(),
  );

  testWidgets('search button names the next step and cards fade in', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = await pumpApp(tester);
    expect(find.text('Start lead search'), findsOneWidget);

    await tester.runAsync(
      () => store.upsertAll([
        lead('cl-1', 'craigslist'),
        lead('direct-2', '').copyWith(source: LeadSource.internal),
      ]),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(repository.leads.value, hasLength(2));
    expect(find.text('Refresh leads'), findsOneWidget);
    expect(find.text('Craigslist'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SourceBadge),
        matching: find.text('Direct Customer'),
      ),
      findsOneWidget,
    );
    // Direct posts can be filtered on their own.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Direct Customer'));
    await tester.pumpAndSettle();
    expect(find.text('Job direct-2'), findsOneWidget);
    expect(find.text('Job cl-1'), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await tester.pumpAndSettle();

    final opacities = tester
        .widgetList<FadeTransition>(
          find.ancestor(
            of: find.text('Job cl-1'),
            matching: find.byType(FadeTransition),
          ),
        )
        .map((fade) => fade.opacity.value);
    expect(opacities, everyElement(1.0), reason: 'entrance finished');
  });

  testWidgets('direct customer posts get their own badge color', (
    tester,
  ) async {
    late (Color, Color) craigslist;
    late (Color, Color) direct;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            craigslist = sourceColors(context, lead('cl-1', 'craigslist'));
            direct = sourceColors(
              context,
              lead('d-1', '').copyWith(source: LeadSource.internal),
            );
            return const SizedBox();
          },
        ),
      ),
    );
    expect(craigslist, isNot(direct));
  });

  testWidgets('dark mode can be picked on the Profile tab and is saved', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = await pumpApp(tester);
    await tester.tap(find.byTooltip('Edit search area'));
    await tester.pumpAndSettle();

    final profileList = find
        .descendant(
          of: find.byType(ProfileScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    // Scroll past it so the bottom navigation bar doesn't cover it.
    await tester.scrollUntilVisible(
      find.text('Direct customer posts'),
      200,
      scrollable: profileList,
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Dark'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(repository.themeMode.value, ThemeMode.dark);
    expect(store.themeMode, 'dark', reason: 'remembered');
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.byType(ProfileScreen))).brightness,
      Brightness.dark,
    );
  });

  testWidgets(
    'the header flips light and dark; trade and filters share a bar',
    (tester) async {
      await tester.runAsync(
        () => store.upsertAll([lead('cl-1', 'craigslist')]),
      );
      final repository = await pumpApp(tester);
      await tester.pumpAndSettle();

      // The trade sits in the filter bar, beside the category chips.
      final trade = find.bySemanticsLabel('Trade: Plumbing. Change trade');
      final all = find.widgetWithText(ChoiceChip, 'All');
      expect(tester.getCenter(trade).dy, closeTo(tester.getCenter(all).dy, 1));
      expect(tester.getCenter(trade).dx, lessThan(tester.getCenter(all).dx));

      Brightness brightness() =>
          Theme.of(tester.element(find.byType(HomeScreen))).brightness;
      expect(brightness(), Brightness.light);
      await tester.runAsync(
        () => tester.tap(find.byTooltip('Switch to dark mode')),
      );
      await tester.pumpAndSettle();
      expect(repository.themeMode.value, ThemeMode.dark);
      expect(brightness(), Brightness.dark);
      expect(store.themeMode, 'dark', reason: 'remembered');

      await tester.runAsync(
        () => tester.tap(find.byTooltip('Switch to light mode')),
      );
      await tester.pumpAndSettle();
      expect(repository.themeMode.value, ThemeMode.light);
      expect(brightness(), Brightness.light);
    },
  );

  testWidgets('the trade picker switches the search from one compact row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(
      () => store.upsertAll([
        lead('cl-old', 'craigslist'),
        lead('cl-kept', 'craigslist').copyWith(isFavorite: true),
        lead('direct-1', '').copyWith(source: LeadSource.internal),
      ]),
    );
    final repository = await pumpApp(tester);
    await tester.pumpAndSettle();
    Finder picker(String trade) =>
        find.text('Trade: $trade', findRichText: true);
    expect(picker('Plumbing'), findsOneWidget);
    // One button, not a row of tabs, even on a wide screen.
    expect(find.text('Moving'), findsNothing);
    expect(
      tester
          .getSize(find.bySemanticsLabel('Trade: Plumbing. Change trade'))
          .height,
      lessThan(56),
    );

    // A filter picked under one trade doesn't carry over to the next.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Direct Customer'));
    await tester.pumpAndSettle();
    expect(find.text('Job cl-kept'), findsNothing);

    // Opened in real async, so the switch that follows the pick (a Hive
    // write and a search) runs there too.
    await tester.runAsync(() => tester.tap(picker('Plumbing')));
    await tester.pumpAndSettle();
    expect(find.text('Choose your trade'), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Plumbing'))
          .selected,
      isTrue,
    );
    expect(find.text('Other trade…'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Moving'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.text('Choose your trade'), findsNothing, reason: 'closed');
    expect(repository.profile.value?.profession, 'movers');
    expect(store.searchProfile?.profession, 'movers', reason: 'saved');
    expect(picker('Moving'), findsOneWidget);
    expect(picker('Plumbing'), findsNothing);
    // The old trade's listings go; saved leads and direct posts stay.
    expect(store.ids, {'cl-kept', 'direct-1'});
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'All'))
          .selected,
      isTrue,
    );
    expect(find.text('Job cl-kept'), findsOneWidget);
  });

  testWidgets('a failed search and the AI tip are short, closable notices', (
    tester,
  ) async {
    final repository = await pumpApp(
      tester,
      client: MockClient((_) => throw http.ClientException('no route')),
    );
    await tester.runAsync(repository.refresh);
    await tester.pumpAndSettle();

    final error = find.widgetWithText(Notice, 'Retry');
    expect(error, findsOneWidget);
    expect(
      find.descendant(of: error, matching: find.textContaining('offline')),
      findsOneWidget,
    );
    expect(find.textContaining('Gemini'), findsNothing, reason: 'no jargon');

    if (!AppConfig.hasGeminiKey) {
      final tip = find.widgetWithText(Notice, 'AI spam filter is off');
      expect(tip, findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(
          find.descendant(of: tip, matching: find.byTooltip('Dismiss')),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(tip, findsNothing);
      expect(store.aiNoticeDismissed, isTrue, reason: 'remembered');
    }

    await tester.tap(
      find.descendant(of: error, matching: find.byTooltip('Dismiss')),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(Notice, 'Retry'), findsNothing);
  });

  testWidgets('one control panel holds the search, filters and stats', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(
      () => store.upsertAll([
        lead('cl-1', 'craigslist'),
        lead('cl-2', 'craigslist'),
      ]),
    );
    await pumpApp(tester);
    await tester.pumpAndSettle();

    final panel = find.byType(SearchProfileBar);
    Finder inPanel(Finder finder) =>
        find.descendant(of: panel, matching: finder);
    expect(inPanel(find.text('Within 25 mi of 10001')), findsOneWidget);
    expect(inPanel(find.byTooltip('Refresh leads')), findsOneWidget);
    expect(inPanel(find.byTooltip('Edit search area')), findsOneWidget);
    expect(inPanel(find.text('Trade: Plumbing', findRichText: true)), findsOne);
    expect(inPanel(find.widgetWithText(ChoiceChip, 'All')), findsOneWidget);
    expect(inPanel(find.text('Open leads')), findsOneWidget);
    if (!AppConfig.hasGeminiKey) {
      // The AI tip rides along in the chips, not in a row of its own.
      expect(
        inPanel(find.widgetWithText(Notice, 'AI spam filter is off')),
        findsOneWidget,
      );
    }
    expect(
      find.byType(Notice).evaluate().length,
      inPanel(find.byType(Notice)).evaluate().length,
      reason: 'no banner rows above the feed',
    );

    // The first lead shows in the top half of a phone screen.
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(
      tester.getTopLeft(find.byType(LeadCard).first).dy,
      lessThan(screen.height * 0.4),
    );
  });

  testWidgets('the summary row leaves hourly rates out of the average', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(
      () => store.upsertAll([
        lead('cl-1', 'craigslist').copyWith(budget: r'$85/hr', price: 85),
        lead('cl-2', 'craigslist').copyWith(budget: r'$1,000', price: 1000),
        lead('cl-3', 'craigslist').copyWith(budget: r'$500 flat', price: 500),
      ]),
    );
    await pumpApp(tester);
    await tester.pumpAndSettle();
    expect(find.text(r'$750'), findsOneWidget);
    expect(find.text('3'), findsWidgets);
    expect(find.text('Open leads'), findsOneWidget);
  });

  test('the store remembers backoff strikes per host', () async {
    expect(store.strikes('www.craigslist.org'), 0);
    await store.saveStrikes('www.craigslist.org', 3);
    expect(store.strikes('www.craigslist.org'), 3);
    expect(store.strikes('other.example.com'), 0);
    await store.saveStrikes('www.craigslist.org', 0);
    expect(store.strikes('www.craigslist.org'), 0);
  });
}
