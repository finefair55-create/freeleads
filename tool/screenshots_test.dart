// Renders the main screens to PNGs with the real Roboto and Material Icons
// fonts, for design review and store/showcase images. Not part of
// `flutter test` (lives outside test/). Run:
//   flutter test tool/screenshots_test.dart
// Images land in build/screenshots/ (override with --dart-define=OUT=dir).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_leads/app.dart';
import 'package:free_leads/app_scope.dart';
import 'package:free_leads/models/lead.dart';
import 'package:free_leads/models/search_profile.dart';
import 'package:free_leads/screens/map_screen.dart';
import 'package:free_leads/services/firestore_service.dart';
import 'package:free_leads/services/lead_repository.dart';
import 'package:free_leads/services/listing_pipeline.dart';
import 'package:free_leads/services/local_lead_store.dart';
import 'package:free_leads/services/zip_geocoder.dart';
import 'package:free_leads/theme/app_theme.dart';
import 'package:hive_ce/hive_ce.dart';

const _out = String.fromEnvironment('OUT', defaultValue: 'build/screenshots');
const _phone = Size(390, 844);
const _desktop = Size(1280, 820);

Future<void> _loadFonts() async {
  final fonts =
      '${Platform.environment['FLUTTER_ROOT'] ?? _flutterRoot()}'
      '/bin/cache/artifacts/material_fonts';
  Future<ByteData> read(String name) async =>
      ByteData.sublistView(await File('$fonts/$name').readAsBytes());
  final roboto = FontLoader('Roboto');
  for (final weight in ['Light', 'Regular', 'Medium', 'Bold', 'Black']) {
    roboto.addFont(read('Roboto-$weight.ttf'));
  }
  await roboto.load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(read('MaterialIcons-Regular.otf'))).load();
}

String _flutterRoot() {
  final flutter = Process.runSync('which', [
    'flutter',
  ]).stdout.toString().trim();
  return File(flutter)
      .resolveSymbolicLinksSync()
      .replaceAll('/bin/flutter', '');
}

List<Lead> _sampleLeads() {
  final now = DateTime.now();
  Lead lead(
    String id,
    String title,
    String description, {
    required String category,
    required String location,
    required String zip,
    double? price,
    LeadTrust trust = LeadTrust.reliable,
    LeadSource source = LeadSource.scraped,
    Duration age = const Duration(hours: 3),
    String? contact,
    List<String> reasons = const [],
  }) => Lead(
    id: id,
    title: title,
    description: description,
    category: category,
    location: location,
    zipCode: zip,
    price: price,
    budget: price == null ? null : '\$${price.round()}',
    source: source,
    board: source == LeadSource.scraped ? 'craigslist' : null,
    createdAt: now.subtract(age),
    contactInfo: contact,
    sourceUrl: source == LeadSource.scraped
        ? 'https://newyork.craigslist.org/mnh/lbg/d/$id.html'
        : null,
    trust: trust,
    trustReasons: reasons,
    trustByAi: source == LeadSource.scraped,
  );
  return [
    lead(
      'cl-1',
      'Replace leaking kitchen faucet and shutoff valve',
      'Single-handle faucet, parts already bought. Weekday mornings work '
          'best. Building has a freight elevator.',
      category: 'Plumbing',
      location: 'Chelsea',
      zip: '10001',
      price: 180,
      contact: '212-555-0142',
      reasons: ['Clear scope, local address and a fair budget.'],
    ),
    lead(
      'direct-1',
      'Bathroom sink drains slowly, need it fixed this week',
      'Tried a plunger, no luck. Prewar building, 3rd floor walk-up.',
      category: 'Plumbing',
      location: 'West Village',
      zip: '10014',
      price: 120,
      source: LeadSource.internal,
      age: const Duration(minutes: 40),
    ),
    lead(
      'cl-2',
      'Install new water heater (40 gal, gas)',
      'Old unit is leaking at the base. Looking for a licensed plumber who '
          'can haul away the old tank.',
      category: 'Plumbing',
      location: 'Murray Hill',
      zip: '10016',
      price: 950,
      age: const Duration(hours: 9),
      reasons: ['Specific job with a realistic budget.'],
    ),
    lead(
      'cl-3',
      'Toilet runs constantly, flapper replaced already',
      'Might be the fill valve. Flexible on timing.',
      category: 'Plumbing',
      location: 'Gramercy',
      zip: '10003',
      trust: LeadTrust.questionable,
      age: const Duration(days: 1, hours: 2),
      reasons: ['No budget or contact details given.'],
    ),
    lead(
      'cl-4',
      'Garbage disposal replacement',
      'InSinkErator 1/2 hp, unit on hand. Need install and old one removed.',
      category: 'Plumbing',
      location: 'Brooklyn Heights',
      zip: '11201',
      price: 140,
      age: const Duration(days: 2),
    ),
  ];
}

void main() {
  late Directory dir;
  late LocalLeadStore store;

  setUpAll(() async {
    await _loadFonts();
    await _makeTile();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('free_leads_shots_');
    store = await LocalLeadStore.open(path: dir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  final boundary = GlobalKey();

  Future<void> shoot(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$_out/$name.png')..createSync(recursive: true);
      file.writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  void size(WidgetTester tester, Size logical) {
    tester.view.physicalSize = logical;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<LeadRepository> pumpApp(
    WidgetTester tester, {
    bool leads = true,
    ThemeMode theme = ThemeMode.light,
  }) async {
    await tester.runAsync(() async {
      await store.saveSearchProfile(
        const SearchProfile(profession: 'plumber', zipCode: '10001'),
      );
      if (leads) {
        await store.upsertAll(_sampleLeads());
      }
    });
    final repository = LeadRepository(
      local: store,
      community: FirestoreService.unavailable(),
      pipeline: ListingPipeline(sources: const []),
      autoRefreshInterval: null,
    )..start();
    repository.themeMode.value = theme;
    addTearDown(repository.dispose);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: FreeLeadsApp(repository: repository),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    return repository;
  }

  testWidgets('feed, phone', (tester) async {
    size(tester, _phone);
    await pumpApp(tester);
    await shoot(tester, 'feed_phone');
  });

  testWidgets('feed, phone, dark', (tester) async {
    size(tester, _phone);
    await pumpApp(tester, theme: ThemeMode.dark);
    await shoot(tester, 'feed_phone_dark');
  });

  testWidgets('feed, desktop', (tester) async {
    size(tester, _desktop);
    await pumpApp(tester);
    await shoot(tester, 'feed_desktop');
  });

  testWidgets('feed loading skeleton', (tester) async {
    size(tester, _phone);
    await tester.runAsync(
      () => store.saveSearchProfile(
        const SearchProfile(profession: 'plumber', zipCode: '10001'),
      ),
    );
    // Never started, so the feed stays in its loading state.
    final repository = LeadRepository(
      local: store,
      community: FirestoreService.unavailable(),
      pipeline: ListingPipeline(sources: const []),
      autoRefreshInterval: null,
    );
    addTearDown(repository.dispose);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: FreeLeadsApp(repository: repository),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 500));
    await shoot(tester, 'feed_skeleton');
  });

  testWidgets('onboarding and profile', (tester) async {
    size(tester, _phone);
    final repository = LeadRepository(
      local: store,
      community: FirestoreService.unavailable(),
      pipeline: ListingPipeline(sources: const []),
      autoRefreshInterval: null,
    )..start();
    addTearDown(repository.dispose);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: FreeLeadsApp(repository: repository),
      ),
    );
    await tester.pumpAndSettle();
    await shoot(tester, 'onboarding_1');
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    await shoot(tester, 'onboarding_2');
  });

  testWidgets('profile tab', (tester) async {
    size(tester, _phone);
    await pumpApp(tester);
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    await shoot(tester, 'profile_phone');
  });

  testWidgets('lead details', (tester) async {
    size(tester, _phone);
    await pumpApp(tester);
    final card = find.text('Replace leaking kitchen faucet and shutoff valve');
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
    await shoot(tester, 'details_phone');
  });

  testWidgets('map with a selected pin', (tester) async {
    size(tester, _phone);
    final repository = await pumpApp(tester);
    await tester.runAsync(ZipGeocoder.instance.ensureLoaded);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: AppScope(
          repository: repository,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            home: Scaffold(body: MapScreen(tileProvider: _PaperTiles())),
          ),
        ),
      ),
    );
    // Let the tile images decode.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pumpAndSettle();
    await shoot(tester, 'map_phone');
    final pin = find.bySemanticsLabel(RegExp('^Install new water heater'));
    if (pin.evaluate().isNotEmpty) {
      await tester.tap(pin);
      await tester.pumpAndSettle();
      await shoot(tester, 'map_phone_selected');
    }
    final badge = find.bySemanticsLabel(RegExp(r'leads here\. Show list$'));
    if (badge.evaluate().isNotEmpty) {
      await tester.tap(badge.first);
      await tester.pumpAndSettle();
      await shoot(tester, 'map_cluster_sheet');
    }
  });
}

/// Plain paper tiles with a faint street grid, so map shots don't need
/// the network.
class _PaperTiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(_tile);
}

late Uint8List _tile;

Future<void> _makeTile() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 256, 256),
    Paint()..color = const Color(0xFFF2EFE9),
  );
  final street = Paint()
    ..color = const Color(0xFFFFFFFF)
    ..strokeWidth = 6;
  for (var i = 0; i < 256; i += 64) {
    canvas.drawLine(Offset(i + 20, 0), Offset(i + 8, 256), street);
    canvas.drawLine(Offset(0, i + 30), Offset(256, i + 40), street);
  }
  final image = await recorder.endRecording().toImage(256, 256);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  _tile = png!.buffer.asUint8List();
}
