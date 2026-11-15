import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:free_leads/app_scope.dart';
import 'package:free_leads/models/lead.dart';
import 'package:free_leads/models/search_profile.dart';
import 'package:free_leads/screens/map_screen.dart';
import 'package:free_leads/services/firestore_service.dart';
import 'package:free_leads/services/lead_repository.dart';
import 'package:free_leads/services/listing_pipeline.dart';
import 'package:free_leads/services/local_lead_store.dart';
import 'package:free_leads/services/zip_geocoder.dart';
import 'package:hive_ce/hive_ce.dart';

const _csv = '''
# comment
94110,37.750,-122.415
94103,37.773,-122.411
94609,37.834,-122.264
10001,40.750,-73.997
19114,40.069,-75.000
19020,40.100,-74.938
08002,39.935,-75.025
19103,39.953,-75.174
08608,40.219,-74.767
19401,40.130,-75.332
bad,line
''';

class _StringBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(utf8.encode(_csv)));
}

/// Serves a blank tile so tests never touch the network.
class _BlankTiles extends TileProvider {
  static final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
  );

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(_png);
}

Lead lead(
  String id,
  String zip, {
  LeadSource source = LeadSource.scraped,
  String? contactInfo,
}) => Lead(
  id: id,
  title: 'Job $id',
  description: 'd',
  category: 'Plumbing',
  location: 'Oakland',
  zipCode: zip,
  source: source,
  contactInfo: contactInfo,
  createdAt: DateTime.now(),
);

void main() {
  test('parses the bundled Census table', () async {
    final csv = File('assets/zip_centroids.csv').readAsStringSync();
    final points = ZipGeocoder.parse(csv);
    expect(points.length, greaterThan(30000));
    expect(points['10001']!.latitude, closeTo(40.75, 0.01));
    expect(points['10001']!.longitude, closeTo(-73.99, 0.01));
  });

  test('a map point resolves to the nearest ZIP, if one is close', () async {
    final geocoder = ZipGeocoder(bundle: _StringBundle());
    expect(
      geocoder.nearestZip(const LatLng(37.834, -122.264)),
      isNull,
      reason: 'not loaded yet',
    );
    await geocoder.ensureLoaded();
    expect(geocoder.nearestZip(const LatLng(37.8341, -122.2637)), '94609');
    expect(geocoder.nearestZip(const LatLng(37.76, -122.42)), '94110');
    expect(geocoder.nearestZip(const LatLng(40.7, -74.0)), '10001');
    expect(
      geocoder.nearestZip(const LatLng(39.0, -98.0)),
      isNull,
      reason: 'nowhere near a known ZIP',
    );
  });

  test('one pin per lead, at its ZIP center', () async {
    final geocoder = ZipGeocoder(bundle: _StringBundle());
    await geocoder.ensureLoaded();
    expect(geocoder.lookup('94110-1234'), isNotNull);

    final leads = [
      lead('a', '94110'),
      lead('b', '94110', source: LeadSource.internal),
      lead('c', '94110'),
      lead('d', '94609'),
      lead('e', ''),
      lead('f', '00000'),
    ];
    final (:pins, :unmapped, :outside) = placeLeadPins(leads, geocoder);
    expect(unmapped, 2);
    expect(outside, 0, reason: 'no search area, nothing filtered');
    expect(pins, hasLength(4));
    for (final pin in pins) {
      expect(pin.zipCenter, geocoder.lookup(pin.lead.zipCode));
    }
    // Community orders draw on top (last).
    expect(pins.last.lead.id, 'b');
    // Stable regardless of feed order.
    expect(
      placeLeadPins(leads.reversed, geocoder).pins.map((p) => p.lead.id),
      pins.map((p) => p.lead.id),
    );
  });

  test('leads sharing a ZIP are one cluster at every zoom', () async {
    final geocoder = ZipGeocoder(bundle: _StringBundle());
    await geocoder.ensureLoaded();
    final leads = [
      for (var i = 0; i < 38; i++) lead('busy$i', '94609'),
      lead('a', '94110'),
    ];
    final pins = placeLeadPins(leads, geocoder).pins;
    for (final zoom in [12.0, 15.5, 18.0]) {
      final clusters = clusterLeadPins(pins, zoom: zoom, radiusPx: 48);
      expect(clusters, hasLength(2), reason: 'zoom $zoom');
      final busy = clusters.firstWhere((c) => c.pins.length > 1);
      expect(busy.pins, hasLength(38));
      expect(busy.sameSpot, isTrue);
      expect(busy.point, geocoder.lookup('94609'));
      final single = clusters.firstWhere((c) => c.pins.length == 1);
      expect(single.pins.single.lead.id, 'a');
    }
  });

  test(
    'nearby ZIPs share a marker until zooming in pulls them apart',
    () async {
      final geocoder = ZipGeocoder(bundle: _StringBundle());
      await geocoder.ensureLoaded();
      // 94110 and 94103 are about 2.6 km apart.
      final pins = placeLeadPins([
        lead('a', '94110'),
        lead('b', '94110'),
        lead('c', '94103'),
      ], geocoder).pins;
      final far = clusterLeadPins(pins, zoom: 11, radiusPx: 48);
      expect(far, hasLength(1));
      expect(far.single.sameSpot, isFalse, reason: 'zooming in separates');
      expect(far.single.zipCenters, hasLength(2));

      final near = clusterLeadPins(pins, zoom: 13, radiusPx: 48);
      expect(near.map((c) => c.pins.length).toList()..sort(), [1, 2]);
      // Clustered at the half level below: no regrouping within one.
      expect(
        clusterLeadPins(pins, zoom: 13.4, radiusPx: 48).map((c) => c.key),
        near.map((c) => c.key),
      );
    },
  );

  test('leads far outside the search area get no pin', () async {
    final geocoder = ZipGeocoder(bundle: _StringBundle());
    await geocoder.ensureLoaded();
    final leads = [lead('a', '94110'), lead('b', '94609'), lead('ny', '10001')];
    final (:pins, :unmapped, :outside) = placeLeadPins(
      leads,
      geocoder,
      area: geocoder.lookup('94110'),
      areaMiles: 100,
    );
    expect(pins.map((p) => p.lead.id), unorderedEquals(['a', 'b']));
    expect(unmapped, 0);
    expect(outside, 1);
  });

  test('zoomed out, nearby leads merge into one region per area', () async {
    final geocoder = ZipGeocoder(bundle: _StringBundle());
    await geocoder.ensureLoaded();
    final leads = [
      for (var i = 0; i < 12; i++) lead('oak$i', '94609'),
      lead('a', '94110'),
      lead('b', '94103'),
      lead('ny', '10001'),
    ];
    final pins = placeLeadPins(leads, geocoder).pins;
    final regions = clusterLeadPins(pins, zoom: 4);
    expect(regions, hasLength(2), reason: 'Bay Area and New York');
    final bay = regions.firstWhere((r) => r.pins.length > 1);
    expect(bay.pins, hasLength(14));
    expect(bay.point.latitude, closeTo(37.8, 0.1));
    expect(bay.point.longitude, closeTo(-122.3, 0.1));

    // Stable regardless of feed order, and only regrouped at half levels.
    final again = clusterLeadPins(
      placeLeadPins(leads.reversed, geocoder).pins,
      zoom: 4.4,
    );
    expect(again.map((r) => r.key).toSet(), regions.map((r) => r.key).toSet());

    // Closer in, the Bay Area's ZIPs split apart again.
    expect(clusterLeadPins(pins, zoom: 11).length, greaterThan(regions.length));
  });

  group('map screen', () {
    late Directory dir;
    late LocalLeadStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('free_leads_map_');
      store = await LocalLeadStore.open(path: dir.path);
    });

    tearDown(() async {
      await Hive.deleteFromDisk();
      await dir.delete(recursive: true);
    });

    testWidgets('a lone lead is a pin; leads sharing a ZIP are a badge', (
      tester,
    ) async {
      await tester.runAsync(
        () => store.upsertAll([
          lead('a', '94110', contactInfo: 'call 510-555-0142'),
          lead('b', '94110'),
          lead('c', '94609', source: LeadSource.internal),
          lead('d', ''),
        ]),
      );
      final repository = LeadRepository(
        local: store,
        community: FirestoreService.unavailable(),
        pipeline: ListingPipeline(),
        autoRefreshInterval: null,
      )..start();
      addTearDown(repository.dispose);
      final geocoder = ZipGeocoder(bundle: _StringBundle());
      await tester.runAsync(geocoder.ensureLoaded);

      await tester.pumpWidget(
        AppScope(
          repository: repository,
          child: MaterialApp(
            home: Scaffold(
              body: MapScreen(geocoder: geocoder, tileProvider: _BlankTiles()),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('3 leads on the map · 1 without a ZIP'), findsOneWidget);
      expect(find.byKey(const ValueKey('lead-c')), findsOneWidget);
      // a and b share 94110: one badge, never two pins on one spot.
      expect(find.byKey(const ValueKey('lead-a')), findsNothing);
      expect(find.byKey(const ValueKey('lead-b')), findsNothing);
      final badge = find.bySemanticsLabel('2 leads here. Show list');
      expect(badge, findsOneWidget);

      await tester.tap(find.bySemanticsLabel(RegExp('^Job c, ')));
      await tester.pumpAndSettle();
      expect(find.text('Job c'), findsOneWidget, reason: 'callout');
      expect(find.byType(BottomSheet), findsNothing, reason: 'preview only');

      // Tapping the map elsewhere dismisses the preview.
      await tester.tapAt(const Offset(60, 300));
      // The map waits out the double-tap window before reporting a tap.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('Job c'), findsNothing);

      // The badge lists its leads, each with a way to reply when it has one.
      await tester.tap(badge);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('2 leads here'), findsOneWidget);
      expect(find.text('Oakland · 94110'), findsOneWidget);
      expect(find.text('Job a'), findsOneWidget);
      expect(find.text('Job b'), findsOneWidget);
      expect(find.text('Reply'), findsOneWidget, reason: 'only a has contact');

      // A row opens the lead's details over the list.
      await tester.tap(find.text('Job b'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNWidgets(2), reason: 'details');
      expect(find.text('Delete'), findsNothing, reason: 'not my lead');
    });

    Future<void> pumpMap(
      WidgetTester tester,
      List<Lead> leads, {
      MapFocus? focus,
      SearchProfile? profile,
    }) async {
      await tester.runAsync(() async {
        await store.upsertAll(leads);
        if (profile != null) {
          await store.saveSearchProfile(profile);
        }
      });
      final repository = LeadRepository(
        local: store,
        community: FirestoreService.unavailable(),
        pipeline: ListingPipeline(),
        autoRefreshInterval: null,
      )..start();
      addTearDown(repository.dispose);
      final geocoder = ZipGeocoder(bundle: _StringBundle());
      await tester.runAsync(geocoder.ensureLoaded);
      await tester.pumpWidget(
        AppScope(
          repository: repository,
          child: MaterialApp(
            home: Scaffold(
              body: MapScreen(
                geocoder: geocoder,
                tileProvider: _BlankTiles(),
                focus: focus,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
    }

    testWidgets('a metro view shows each town apart, with its own count', (
      tester,
    ) async {
      // A 25-mile search from Northeast Philly, at the zoom the map opens on.
      const profile = SearchProfile(
        profession: 'plumber',
        zipCode: '19114',
        radiusMiles: 25,
      );
      await pumpMap(tester, [
        for (var i = 0; i < 3; i++) lead('bensalem$i', '19020'),
        for (var i = 0; i < 2; i++) lead('cherryhill$i', '08002'),
        lead('centercity', '19103'),
        lead('trenton', '08608'),
        lead('norristown', '19401'),
      ], profile: profile);

      expect(find.bySemanticsLabel(RegExp('in this area')), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp(r'^8 leads (here|nearby)')),
        findsNothing,
      );
      expect(find.bySemanticsLabel('3 leads here. Show list'), findsOneWidget);
      expect(find.bySemanticsLabel('2 leads here. Show list'), findsOneWidget);
      for (final id in ['centercity', 'trenton', 'norristown']) {
        expect(find.byKey(ValueKey('lead-$id')), findsOneWidget, reason: id);
      }

      // Tapping a town's badge lists just that town's leads.
      await tester.tap(find.bySemanticsLabel('2 leads here. Show list'));
      await tester.pumpAndSettle();
      expect(find.text('2 leads here'), findsOneWidget);
      expect(find.textContaining('08002'), findsOneWidget);
      expect(find.text('Job cherryhill0'), findsOneWidget);
      expect(find.text('Job bensalem0'), findsNothing);
      Navigator.of(tester.element(find.text('2 leads here'))).pop();
      await tester.pumpAndSettle();

      // Only a multi-state view merges them into one regional count.
      final controller = MapController.maybeOf(
        tester.element(find.byType(MarkerLayer)),
      )!;
      controller.move(controller.camera.center, MapScreen.pinZoom - 0.5);
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('8 leads in this area. Zoom in'),
        findsOneWidget,
      );
    });

    testWidgets('the search radius is a ring, with no filled box under it', (
      tester,
    ) async {
      const profile = SearchProfile(profession: 'plumber', zipCode: '94110');
      await pumpMap(tester, [lead('a', '94110')], profile: profile);
      // A CircleMarker's fill, even a transparent one, draws as a square
      // on Impeller; the ring is a stroke-only polyline instead.
      expect(find.byType(CircleLayer), findsNothing);
      expect(find.byType(PolygonLayer), findsNothing);
      final ring = tester
          .widget<PolylineLayer>(find.byType(PolylineLayer))
          .polylines
          .single;
      expect(ring.strokeWidth, greaterThan(0));
      expect(ring.color.a, greaterThan(0));
      expect(ring.points.first, ring.points.last, reason: 'closed');
      const distance = Distance();
      const home = LatLng(37.750, -122.415);
      final meters = profile.radiusMiles * 1609.34;
      for (final point in ring.points) {
        expect(distance(home, point), closeTo(meters, meters * 0.01));
      }
    });

    testWidgets('Show on map flies to the lead and previews it', (
      tester,
    ) async {
      final focus = MapFocus();
      addTearDown(focus.dispose);
      final leads = [
        lead('a', '94110'),
        lead('far', '10001'),
        for (var i = 0; i < 6; i++)
          lead(
            'busy$i',
            '94609',
          ).copyWith(postedAt: DateTime.now().subtract(Duration(hours: 9 - i))),
      ];
      // Asked before the map has loaded: it waits for the map.
      focus.show(leads.first);
      await pumpMap(tester, leads, focus: focus);
      expect(find.text('Job a'), findsOneWidget, reason: 'preview open');
      expect(find.text('View details'), findsOneWidget);
      final controller = MapController.maybeOf(
        tester.element(find.byKey(const ValueKey('lead-a'))),
      )!;
      expect(controller.camera.zoom, greaterThanOrEqualTo(13));
      const distance = Distance();
      expect(
        distance(controller.camera.center, const LatLng(37.750, -122.415)),
        lessThan(3000),
        reason: 'centered near the lead, nudged clear of the card',
      );

      // A lead in a busy ZIP previews on its own, its badge highlighted.
      focus.show(leads.last);
      await tester.pumpAndSettle();
      expect(find.text('Job busy5'), findsOneWidget);
      expect(find.text('Job a'), findsNothing);
      expect(find.text('1 / 6'), findsNothing, reason: 'no paging');
      expect(
        tester.getSemantics(find.bySemanticsLabel('6 leads here. Show list')),
        isSemantics(isSelected: true),
      );
    });

    testWidgets('zoomed out, leads show as regions; a tap zooms to pins', (
      tester,
    ) async {
      final leads = [
        for (var i = 0; i < 38; i++)
          lead('busy$i', '94609', contactInfo: 'call 510-555-0142'),
        lead('a', '94110'),
        lead('b', '94103'),
        lead('far', '10001'),
      ];
      // Fitting SF and New York zooms out to the whole country: no pins,
      // one count marker per region.
      await pumpMap(tester, leads);
      expect(find.text('41 leads on the map'), findsOneWidget);
      expect(find.textContaining('Zoom in or tap a circle'), findsOneWidget);
      final markers = tester.widget<MarkerLayer>(find.byType(MarkerLayer));
      final keys = markers.markers.map((m) => '${m.key}').toList();
      expect(keys.where((k) => k.contains('lead-')), isEmpty);
      expect(keys, hasLength(2), reason: 'Bay Area and New York');
      expect(find.bySemanticsLabel('40 leads in this area. Zoom in'), findsOne);

      await tester.tap(find.bySemanticsLabel('40 leads in this area. Zoom in'));
      await tester.pumpAndSettle();
      final controller = MapController.maybeOf(
        tester.element(find.byType(MarkerLayer)),
      )!;
      expect(controller.camera.zoom, greaterThanOrEqualTo(MapScreen.pinZoom));
      expect(find.byKey(const ValueKey('lead-a')), findsOneWidget);
      expect(find.textContaining('Zoom in or tap a circle'), findsNothing);

      // A pin previews just its own lead, with its contact actions.
      await tester.tap(find.byKey(const ValueKey('lead-a')));
      await tester.pumpAndSettle();
      expect(find.text('Job a'), findsOneWidget);
      expect(find.byTooltip('Next lead'), findsNothing);
      await tester.tap(find.byTooltip('Close preview'));
      await tester.pumpAndSettle();
      expect(find.text('Job a'), findsNothing);
    });

    testWidgets(
      'a busy ZIP stays one badge at every zoom; it lists its leads',
      (tester) async {
        final leads = [
          for (var i = 0; i < 12; i++)
            lead('busy$i', '94609', contactInfo: 'call 510-555-0142'),
        ];
        await pumpMap(tester, leads);
        final controller = MapController.maybeOf(
          tester.element(find.byType(MarkerLayer)),
        )!;
        const center = LatLng(37.834, -122.264);
        final badge = find.bySemanticsLabel('12 leads here. Show list');

        for (final zoom in [12.0, 9.3, 7.6, 15.0, 18.0]) {
          controller.move(center, zoom);
          await tester.pump();
          expect(badge, findsOne, reason: 'zoom $zoom');
          expect(find.byKey(const ValueKey('lead-busy0')), findsNothing);
          // Centered on the ZIP, not spread across the town.
          final at = controller.camera.latLngToScreenOffset(center);
          expect((tester.getCenter(badge) - at).distance, lessThan(0.5));
        }

        // One frame after crossing the threshold, it gives way to a region.
        controller.move(center, MapScreen.pinZoom - 0.1);
        await tester.pump();
        expect(badge, findsNothing);
        expect(
          find.bySemanticsLabel('12 leads in this area. Zoom in'),
          findsOne,
        );
        controller.move(center, MapScreen.pinZoom + 0.1);
        await tester.pump();
        expect(badge, findsOne);

        // Zooming in can't pull one ZIP apart, so a tap lists the leads
        // without moving the camera.
        final zoom = controller.camera.zoom;
        await tester.tap(badge);
        await tester.pumpAndSettle();
        expect(controller.camera.zoom, zoom);
        expect(find.text('12 leads here'), findsOneWidget);
        expect(find.textContaining('Job busy'), findsWidgets);
        expect(find.widgetWithText(FilledButton, 'Reply'), findsWidgets);
      },
    );

    testWidgets('a badge over nearby ZIPs zooms in until they separate', (
      tester,
    ) async {
      await pumpMap(tester, [
        lead('a', '94110'),
        lead('b', '94110'),
        lead('c', '94103'),
      ]);
      final controller = MapController.maybeOf(
        tester.element(find.byType(MarkerLayer)),
      )!;
      // About 2.6 km apart: closer than a badge at this zoom.
      controller.move(const LatLng(37.76, -122.413), 11);
      await tester.pump();
      final nearby = find.bySemanticsLabel('3 leads nearby. Zoom in');
      expect(nearby, findsOne);

      await tester.tap(nearby);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(controller.camera.zoom, greaterThan(12));
      expect(find.bySemanticsLabel('2 leads here. Show list'), findsOne);
      expect(find.byKey(const ValueKey('lead-c')), findsOneWidget);
    });

    testWidgets('a search area keeps far-off ZIPs off the map', (tester) async {
      const profile = SearchProfile(profession: 'plumber', zipCode: '94110');
      await pumpMap(tester, [
        lead('a', '94110'),
        lead('b', '94609'),
        lead('ny', '10001'),
      ], profile: profile);
      expect(
        find.text('2 leads on the map · 1 outside your area'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('lead-ny')), findsNothing);
      expect(find.byKey(const ValueKey('lead-a')), findsOneWidget);
    });

    for (final (width, scale) in [(320.0, 1.3), (360.0, 2.0)]) {
      testWidgets('preview fits ${width.round()}px at ${scale}x text', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        await pumpMap(tester, [
          lead(
            'busy0',
            '94609',
            contactInfo: '510-555-0142 or help@example.com',
          ).copyWith(budget: r'$45/hr plus parts, negotiable'),
        ]);
        await tester.tap(find.byKey(const ValueKey('lead-busy0')));
        await tester.pumpAndSettle();
        expect(find.text('View details'), findsOneWidget);
        // Phone and email: Reply offers each way to reach them.
        await tester.tap(find.text('Reply'));
        await tester.pumpAndSettle();
        for (final label in ['Call', 'Text', 'Email']) {
          expect(find.widgetWithText(MenuItemButton, label), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }
  });
}
