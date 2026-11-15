import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_leads/app.dart';
import 'package:free_leads/models/search_profile.dart';
import 'package:free_leads/services/firestore_service.dart';
import 'package:free_leads/services/lead_repository.dart';
import 'package:free_leads/services/listing_pipeline.dart';
import 'package:free_leads/services/local_lead_store.dart';
import 'package:free_leads/widgets/safe_async.dart';
import 'package:free_leads/widgets/skeleton.dart';
import 'package:hive_ce/hive_ce.dart';

void main() {
  late Directory dir;
  late LocalLeadStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('free_leads_motion_');
    store = await LocalLeadStore.open(path: dir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  Future<LeadRepository> pumpApp(WidgetTester tester) async {
    await tester.runAsync(
      () => store.saveSearchProfile(
        const SearchProfile(profession: 'plumber', zipCode: '10001'),
      ),
    );
    final repository = LeadRepository(
      local: store,
      community: FirestoreService.unavailable(),
      pipeline: ListingPipeline(sources: const []),
      autoRefreshInterval: null,
    );
    addTearDown(repository.dispose);
    await tester.pumpWidget(FreeLeadsApp(repository: repository));
    await tester.pump();
    return repository;
  }

  testWidgets('feed shows shimmer cards until stored leads load', (
    tester,
  ) async {
    final repository = await pumpApp(tester);
    expect(find.byType(LeadCardSkeleton), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.hasRunningAnimations, isTrue, reason: 'shimmer sweeps');

    repository.start();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byType(LeadCardSkeleton), findsNothing);
    expect(find.widgetWithText(StatusPane, 'No leads yet'), findsOneWidget);
  });

  testWidgets('shimmer holds still when the device asks for less motion', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    await pumpApp(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LeadCardSkeleton), findsWidgets);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('switching tabs fades the new tab in', (tester) async {
    final repository = await pumpApp(tester);
    repository.start();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Post'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    double opacity() => tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.byType(IndexedStack),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;
    expect(opacity(), inExclusiveRange(0, 1), reason: 'mid-fade');

    await tester.pumpAndSettle();
    expect(opacity(), 1);
    expect(find.text('Post a lead'), findsOneWidget);
  });
}
