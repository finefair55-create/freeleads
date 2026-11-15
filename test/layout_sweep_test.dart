import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_leads/app.dart';
import 'package:free_leads/models/lead.dart';
import 'package:free_leads/models/search_profile.dart';
import 'package:free_leads/screens/home_screen.dart';
import 'package:free_leads/services/firestore_service.dart';
import 'package:free_leads/services/lead_repository.dart';
import 'package:free_leads/services/listing_pipeline.dart';
import 'package:free_leads/services/local_lead_store.dart';
import 'package:free_leads/widgets/lead_details_sheet.dart';
import 'package:hive_ce/hive_ce.dart';

/// Renders every tab on a small phone with large text and in a wide
/// desktop window, and fails on any overflow or build error.
void main() {
  late Directory dir;
  late LocalLeadStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('free_leads_sweep_');
    store = await LocalLeadStore.open(path: dir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  final leads = [
    Lead(
      id: 'cl-caps',
      title: 'DO YOU FIX APPLIANCES? WE NEED TECHS NOW !!!',
      description: 'Washer, dryer and two fridges at a rental. ' * 4,
      category: 'Appliance Repair',
      location: 'Northern Liberties and Fishtown border',
      zipCode: '19123',
      budget: r'$45/hr plus parts, negotiable depending on experience',
      price: 45,
      contactInfo: '215-555-0100',
      source: LeadSource.scraped,
      board: 'craigslist',
      trust: LeadTrust.questionable,
      postedAt: DateTime.now().subtract(const Duration(hours: 3)),
    ),
    for (var i = 0; i < 6; i++)
      Lead(
        id: 'cl-$i',
        title: 'Replace kitchen faucet and garbage disposal unit $i',
        description: 'Parts on site.',
        category: Lead.categories[i],
        location: 'Chelsea',
        zipCode: '10001',
        price: 150.0 * (i + 1),
        source: LeadSource.scraped,
        board: 'craigslist',
        trust: LeadTrust.values[i % 3],
        createdAt: DateTime.now(),
      ),
    Lead(
      id: 'direct-1',
      title: 'Need movers Saturday',
      description: 'Two bedroom apartment, third floor walk-up.',
      category: 'Moving',
      location: 'Midtown',
      zipCode: '10018',
      contactInfo: 'mover-request@example.com',
      source: LeadSource.internal,
      isFavorite: true,
      createdAt: DateTime.now(),
    ),
  ];

  const sizes = {
    'small phone, large text': (Size(320, 568), 1.3),
    'phone, huge text': (Size(360, 780), 2.0),
    'wide desktop': (Size(1920, 1080), 1.0),
  };

  for (final MapEntry(key: name, value: (size, scale)) in sizes.entries) {
    testWidgets('every tab fits: $name', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.runAsync(() async {
        await store.saveSearchProfile(
          const SearchProfile(profession: 'appliance repair', zipCode: '10001'),
        );
        await store.upsertAll(leads);
      });
      final repository = LeadRepository(
        local: store,
        community: FirestoreService.unavailable(),
        pipeline: ListingPipeline(sources: const []),
        autoRefreshInterval: null,
      )..start();
      addTearDown(repository.dispose);
      // Collect every layout error with the step and the widget that
      // caused it, instead of stopping at the first.
      final problems = <String>[];
      var step = 'feed';
      final report = FlutterError.onError;
      FlutterError.onError = (details) {
        final summary = details
            .toString()
            .split('\n')
            .where(
              (line) =>
                  line.contains('overflowed') ||
                  line.contains('file:///') ||
                  line.contains('EXCEPTION'),
            );
        problems.add('$step: ${summary.take(3).join(' | ')}');
      };
      try {
        await tester.pumpWidget(FreeLeadsApp(repository: repository));
        await tester.pumpAndSettle();

        // Scroll the feed to the end so every card lays out.
        step = 'feed scrolled';
        await tester.fling(
          find.byType(CustomScrollView).first,
          const Offset(0, -3000),
          3000,
        );
        await tester.pumpAndSettle();

        for (final tab in ['Post', 'Profile']) {
          step = tab;
          await tester.tap(find.text(tab).last);
          await tester.pumpAndSettle();
          final scrollable = find.byType(Scrollable).hitTestable();
          if (tab == 'Profile' && scrollable.evaluate().isNotEmpty) {
            step = '$tab scrolled';
            await tester.fling(scrollable.first, const Offset(0, -4000), 4000);
            await tester.pumpAndSettle();
          }
        }

        step = 'details sheet';
        await tester.tap(find.text('Leads').last);
        await tester.pumpAndSettle();
        unawaited(
          showLeadDetails(tester.element(find.byType(HomeScreen)), leads.first),
        );
        await tester.pumpAndSettle();
      } finally {
        FlutterError.onError = report;
      }
      expect(problems, isEmpty);
    });
  }
}
