import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_leads/app.dart';
import 'package:free_leads/models/lead.dart';
import 'package:free_leads/models/search_profile.dart';
import 'package:free_leads/screens/profile_screen.dart';
import 'package:free_leads/services/firestore_service.dart';
import 'package:free_leads/services/lead_repository.dart';
import 'package:free_leads/services/listing_pipeline.dart';
import 'package:free_leads/services/gemini_service.dart';
import 'package:free_leads/services/local_lead_store.dart';
import 'package:free_leads/sources/craigslist_source.dart';
import 'package:free_leads/sources/listing_fetch_service.dart';
import 'package:free_leads/sources/request_policy.dart';
import 'package:free_leads/widgets/app_logo.dart';
import 'package:hive_ce/hive_ce.dart';

import 'support/fakes.dart';

void main() {
  late Directory dir;
  late LocalLeadStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('free_leads_widget_');
    store = await LocalLeadStore.open(path: dir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  const plumber = SearchProfile(profession: 'plumber', zipCode: '10001');

  /// Pumps the app; with [profile] (the default) onboarding is skipped.
  Future<LeadRepository> pumpApp(
    WidgetTester tester, {
    SearchProfile? profile = plumber,
  }) async {
    if (profile != null) {
      await tester.runAsync(() => store.saveSearchProfile(profile));
    }
    final client = fakeInternet();
    final repository = LeadRepository(
      local: store,
      community: FirestoreService.unavailable(),
      pipeline: ListingPipeline(
        gemini: GeminiService(
          apiKey: '',
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

  testWidgets('dashboard shows stored leads without Firebase', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(
      () => store.upsert(
        Lead(
          id: 'cl-aaa111',
          title: 'Repair leaking water heater',
          description: 'Licensed plumber needed this week.',
          category: 'Plumbing',
          location: 'Oakland',
          zipCode: '94609',
          budget: r'$85/hr',
          source: LeadSource.scraped,
          createdAt: DateTime.now(),
        ),
      ),
    );
    await pumpApp(tester);

    expect(find.text('FreeLeads'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppLogo), matching: find.text('F')),
      findsOneWidget,
      reason: 'minimal F mark in the header',
    );
    expect(find.text('On-device only'), findsOneWidget);
    expect(find.text('Repair leaking water heater'), findsOneWidget);
    expect(find.text(r'$85/hr'), findsWidgets);
    expect(find.text('Open leads'), findsOneWidget);

    // Hive writes real files, so let the tap's write finish in real async.
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Save lead'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(store.get('cl-aaa111')!.isFavorite, isTrue);
    expect(find.byTooltip('Remove from saved'), findsOneWidget);
  });

  testWidgets('a card\'s Show on map opens the Map tab', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(
      () => store.upsertAll([
        Lead(
          id: 'cl-zip',
          title: 'Fix a running toilet',
          description: 'Upstairs bathroom.',
          category: 'Plumbing',
          location: 'Oakland',
          zipCode: '94609',
          source: LeadSource.scraped,
          createdAt: DateTime.now(),
        ),
        Lead(
          id: 'cl-nozip',
          title: 'Unclog a shower drain',
          description: 'Slow drain.',
          category: 'Plumbing',
          location: '',
          zipCode: '',
          source: LeadSource.scraped,
          createdAt: DateTime.now(),
        ),
      ]),
    );
    await pumpApp(tester);
    await tester.pumpAndSettle();

    // Only a lead with a ZIP can go on the map.
    expect(find.byTooltip('Show on map'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Show on map, Oakland · 94609'),
      findsOneWidget,
    );
    int selectedTab() =>
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;
    expect(selectedTab(), 0);

    await tester.tap(find.byTooltip('Show on map'));
    // The map shimmers while its ZIP table loads, so don't wait to settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(selectedTab(), 1);
  });

  testWidgets('empty feed shows a friendly pane, not an error', (tester) async {
    await pumpApp(tester);

    expect(find.text('No leads yet'), findsOneWidget);
    expect(find.text('Search now'), findsNothing);
    expect(find.byTooltip('Search now'), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);
  });

  testWidgets('first launch walks through onboarding and saves the profile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = await pumpApp(tester, profile: null);
    expect(find.text('Find local jobs, free'), findsOneWidget);
    expect(find.text('Leads'), findsNothing, reason: 'no home screen yet');

    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    final continueButton = find.widgetWithText(FilledButton, 'Continue');
    expect(tester.widget<FilledButton>(continueButton).onPressed, isNull);

    await tester.tap(find.text('HVAC'));
    await tester.pump();
    await tester.tap(continueButton);
    await tester.pumpAndSettle();

    final start = find.widgetWithText(FilledButton, 'Start finding leads');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Home ZIP'),
      '123',
    );
    await tester.pump();
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Home ZIP'),
      '94110',
    );
    await tester.tap(find.text('10 mi'));
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(start);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();

    const expected = SearchProfile(
      profession: 'hvac',
      zipCode: '94110',
      radiusMiles: 10,
    );
    expect(repository.profile.value, expected);
    expect(store.searchProfile, expected, reason: 'persisted on-device');
    expect(find.text('Leads'), findsOneWidget, reason: 'home screen shown');
    expect(find.text('Trade: HVAC', findRichText: true), findsOneWidget);
    expect(find.text('Within 10 mi of 94110'), findsOneWidget);
  });

  testWidgets('cards show trust and source badges; spam can be hidden', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Lead lead(String id, String title, String description) => Lead(
      id: id,
      title: title,
      description: description,
      category: 'Plumbing',
      location: 'Oakland',
      zipCode: '94609',
      source: LeadSource.scraped,
      board: 'craigslist',
      createdAt: DateTime.now(),
    );
    await tester.runAsync(
      () => store.upsertAll([
        lead(
          'cl-good',
          'Replace kitchen faucet',
          'Single-handle faucet, parts on site. Weekday mornings work best. '
              'Budget is firm, call 510-555-0142 to schedule a visit.',
        ).copyWith(budget: r'$150', price: 150, contactInfo: '510-555-0142'),
        lead(
          'cl-scam',
          'PLUMBER NEEDED URGENT!!!!',
          'Pay the registration fee by gift card, then text me on WhatsApp.',
        ),
      ]),
    );
    final repository = await pumpApp(tester);

    expect(find.text('Reliable'), findsOneWidget);
    expect(find.text('Possible spam'), findsOneWidget);
    expect(find.text('Craigslist'), findsNWidgets(2));
    // Shown in sentence case; the grader still saw the shouting.
    expect(find.text('Plumber needed urgent!'), findsOneWidget);
    expect(find.text('PLUMBER NEEDED URGENT!!!!'), findsNothing);

    await tester.runAsync(() async {
      await tester.tap(find.text('Hide possible spam'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(repository.hideSpam.value, isTrue);
    expect(store.hideSpam, isTrue, reason: 'remembered');
    expect(find.text('Plumber needed urgent!'), findsNothing);
    expect(find.text('Possible spam hidden (1)'), findsOneWidget);
    // The card offers Reply without opening the lead.
    expect(find.widgetWithText(FilledButton, 'Reply'), findsOneWidget);

    await tester.tap(find.text('Replace kitchen faucet'));
    await tester.pumpAndSettle();
    expect(find.text('Checked on this device'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Call'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Text'), findsOneWidget);
    // Reply and Save stay pinned at the bottom of the sheet.
    final sheetReply = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.widgetWithText(FilledButton, 'Reply'),
    );
    expect(sheetReply, findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    await tester.tap(sheetReply);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MenuItemButton, 'Call'), findsOneWidget);
  });

  testWidgets('posting without Firebase saves the lead on-device', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpApp(tester);
    await tester.tap(find.text('Post'));
    await tester.pumpAndSettle();

    Future<void> fill(String label, String text) =>
        tester.enterText(find.widgetWithText(TextFormField, label), text);
    expect(find.text('Sign in'), findsNothing, reason: 'no Firebase here');
    await fill('Title', 'Fix garbage disposal');
    await tester.tap(find.text('Category'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plumbing').last);
    await tester.pumpAndSettle();
    await fill('Description', 'Disposal hums but does not spin.');
    await fill('ZIP code', '94110');
    await fill('Budget (optional)', r'$120');
    await fill('Contact info', 'text 415-555-0199');

    await tester.runAsync(() async {
      await tester.tap(find.text('Post lead'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    final saved = store.all.single;
    expect(saved.title, 'Fix garbage disposal');
    expect(saved.price, 120);
    expect(saved.zipCode, '94110');
    expect(saved.category, 'Plumbing');
    expect(saved.source, LeadSource.internal);
    expect(find.textContaining('Saved on this device'), findsOneWidget);
  });

  testWidgets('profile tab holds the saved search and imports listings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpApp(tester);

    // Dashboard shows a summary, not a second copy of the form.
    expect(find.text('Trade: Plumbing', findRichText: true), findsOneWidget);
    expect(find.text('Within 25 mi of 10001'), findsOneWidget);
    expect(find.text('Parser'), findsNothing);
    await tester.tap(find.byTooltip('Edit search area'));
    await tester.pumpAndSettle();

    expect(find.text('Your profile'), findsOneWidget);
    final plumbing = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Plumbing'),
    );
    expect(plumbing.selected, isTrue);
    expect(find.widgetWithText(TextFormField, '10001'), findsOneWidget);
    final profileList = find
        .descendant(
          of: find.byType(ProfileScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Craigslist'),
      200,
      scrollable: profileList,
    );
    expect(find.textContaining('requests used this hour'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Import listing text'),
      200,
      scrollable: profileList,
    );

    await tester.tap(find.text('Import listing text'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      r'Need a plumber in Austin TX to fix a leak, about $90',
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Create lead'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text('Add to my leads'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('Add to my leads'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    final saved = store.all.single;
    expect(saved.price, 90);
    expect(saved.zipCode, '10001', reason: 'falls back to the home ZIP');
    expect(find.text('Import listing'), findsNothing, reason: 'popped back');
    expect(find.byType(ProfileScreen), findsOneWidget);
  });
}
