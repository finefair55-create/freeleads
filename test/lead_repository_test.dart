import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_leads/app_scope.dart';
import 'package:free_leads/screens/post_lead_screen.dart';
import 'package:free_leads/models/lead.dart';
import 'package:free_leads/models/raw_listing.dart';
import 'package:free_leads/models/search_profile.dart';
import 'package:free_leads/services/gemini_service.dart';
import 'package:free_leads/sources/listing_source.dart';
import 'package:free_leads/sources/craigslist_source.dart';
import 'package:free_leads/sources/listing_fetch_service.dart';
import 'package:free_leads/sources/request_policy.dart';
import 'package:free_leads/services/firestore_service.dart';
import 'package:free_leads/services/lead_repository.dart';
import 'package:free_leads/services/listing_pipeline.dart';
import 'package:free_leads/services/local_lead_store.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fakes.dart';

/// Firestore stand-in: [confirmWrites] false simulates being offline, and
/// [failDeletes] simulates the rules denying a delete of a missing doc.
class FakeCommunity implements FirestoreService {
  FakeCommunity({
    this.confirmWrites = true,
    this.failDeletes = false,
    bool signedIn = true,
  }) : _account = signedIn ? const PosterAccount(uid: 'me') : null;

  final bool confirmWrites;
  final bool failDeletes;
  final deleted = <String>[];
  final savedProfiles = <SearchProfile>[];
  final _accounts = StreamController<PosterAccount?>.broadcast();
  PosterAccount? _account;
  int signInCalls = 0;

  @override
  bool get isAvailable => true;

  @override
  String? get currentUserId => 'me';

  @override
  Future<String?> ensureSignedIn() async => 'me';

  @override
  PosterAccount? get account => _account;

  @override
  Stream<PosterAccount?> watchAccount() => _accounts.stream;

  @override
  Future<PosterAccount?> signInWithGoogle() async {
    signInCalls++;
    _account = const PosterAccount(
      uid: 'me',
      name: 'Pat Customer',
      email: 'pat@example.com',
    );
    _accounts.add(_account);
    return _account;
  }

  @override
  Future<void> signOut() async {
    _account = null;
    _accounts.add(null);
  }

  @override
  Stream<List<Lead>> watchCommunityLeads({String? zipPrefix}) =>
      Stream.value(const []);

  @override
  Future<({Lead lead, bool confirmed})> postLead(
    Lead lead, {
    Duration ackTimeout = const Duration(seconds: 5),
  }) async {
    if (_account == null) {
      throw const SignInRequiredException();
    }
    return (
      lead: lead.copyWith(
        id: 'doc-1',
        authorId: 'me',
        source: LeadSource.internal,
        createdAt: DateTime.now(),
      ),
      confirmed: confirmWrites,
    );
  }

  @override
  Future<void> saveProfile(
    SearchProfile profile, {
    Duration ackTimeout = const Duration(seconds: 5),
  }) async => savedProfiles.add(profile);

  @override
  Future<SearchProfile?> loadProfile({
    Duration timeout = const Duration(seconds: 5),
  }) async => savedProfiles.lastOrNull;

  @override
  Future<void> deleteLead(
    String id, {
    Duration ackTimeout = const Duration(seconds: 5),
  }) async {
    if (failDeletes) {
      throw StateError('permission-denied');
    }
    deleted.add(id);
  }
}

void main() {
  late Directory dir;
  late LocalLeadStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('free_leads_repo_');
    store = await LocalLeadStore.open(path: dir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  // Never the real sites: a refresh here finds nothing, instantly.
  LeadRepository repo(FakeCommunity community) => LeadRepository(
    local: store,
    community: community,
    pipeline: ListingPipeline(
      gemini: GeminiService(apiKey: ''),
      sources: [SlowSource(Future.value())],
    ),
    autoRefreshInterval: null,
  );

  const order = Lead(
    id: '',
    title: 'Fix sink',
    description: 'Drip',
    category: 'Plumbing',
    location: 'LES',
    zipCode: '10002',
  );

  test('an unconfirmed (offline) post is reported as queued', () async {
    final outcome = await repo(FakeCommunity(confirmWrites: false))
        .postLead(order);
    expect(outcome, PostOutcome.queued);
    expect(store.get('doc-1'), isNotNull, reason: 'kept on-device too');
  });

  test('posting to Firestore needs a Google account', () async {
    await expectLater(
      repo(FakeCommunity(signedIn: false)).postLead(order),
      throwsA(isA<SignInRequiredException>()),
    );
  });

  testWidgets('guests see a sign-in gate; once signed in they can post', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final community = FakeCommunity(signedIn: false);
    final repository = repo(community);
    addTearDown(repository.dispose);
    await tester.pumpWidget(
      AppScope(
        repository: repository,
        child: const MaterialApp(home: Scaffold(body: PostLeadScreen())),
      ),
    );
    await tester.pump();

    expect(find.text('Sign in to post a job'), findsOneWidget);
    expect(find.textContaining('free of spam'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing, reason: 'no form yet');

    await tester.runAsync(() async {
      await tester.tap(find.text('Sign in or register with Google'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(community.signInCalls, 1);
    expect(find.text('Sign in to post a job'), findsNothing);
    expect(find.text('Posting as Pat Customer'), findsOneWidget);

    Future<void> fill(String label, String text) =>
        tester.enterText(find.widgetWithText(TextFormField, label), text);
    await fill('Title', 'Fix sink');
    await tester.tap(find.text('Category'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plumbing').last);
    await tester.pumpAndSettle();
    await fill('Description', 'Drip under the sink.');
    await fill('ZIP code', '10002');
    await fill('Contact info', '212-555-0100');

    await tester.runAsync(() async {
      await tester.tap(find.text('Post lead'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    final posted = store.get('doc-1')!;
    expect(posted.title, 'Fix sink');
    expect(posted.category, 'Plumbing');
    expect(posted.source, LeadSource.internal);

    // Signing out brings the gate back.
    await tester.runAsync(() async {
      await tester.tap(find.text('Sign out'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.text('Sign in to post a job'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
  });

  test('only the author\'s Firestore posts count as shared', () {
    final repository = repo(FakeCommunity());
    const mine = Lead(
      id: 'doc-1',
      title: 'Fix sink',
      description: 'Drip',
      category: 'Plumbing',
      location: '',
      zipCode: '10002',
      authorId: 'me',
    );
    expect(repository.isSharedPost(mine), isTrue);
    expect(repository.isSharedPost(mine.copyWith(authorId: 'other')), isFalse);
    expect(repository.isSharedPost(mine.copyWith(id: 'local-1')), isFalse);
    expect(
      repository.isSharedPost(mine.copyWith(source: LeadSource.parsed)),
      isFalse,
    );
  });

  test('a confirmed post is reported as shared', () async {
    expect(await repo(FakeCommunity()).postLead(order), PostOutcome.shared);
  });

  test(
    'deleting an order already gone remotely still removes it locally',
    () async {
      final community = FakeCommunity(failDeletes: true);
      final repository = repo(community);
      await repository.postLead(order);

      await repository.deleteLead(store.get('doc-1')!);
      expect(store.get('doc-1'), isNull);
    },
  );

  test(
    'a search with no connection flags offline and keeps saved leads',
    () async {
      final offlineClient = MockClient(
        (_) async => throw http.ClientException('Failed host lookup'),
      );
      final repository = LeadRepository(
        local: store,
        community: FakeCommunity(),
        pipeline: ListingPipeline(
          sources: [
            CraigslistSource(
              fetcher: ListingFetchService(
                client: offlineClient,
                maxAttempts: 1,
                policy: RequestPolicy.unthrottled,
              ),
            ),
          ],
        ),
        autoRefreshInterval: null,
      );
      await store.upsert(order.copyWith(id: 'kept'));
      await store.saveSearchProfile(
        const SearchProfile(profession: 'plumber', zipCode: '10001'),
      );
      repository.profile.value = store.searchProfile;

      await repository.refresh();
      expect(repository.offline.value, isTrue);
      expect(repository.status.value.phase, RefreshPhase.failed);
      expect(repository.status.value.message, contains('offline'));
      expect(store.get('kept'), isNotNull);

      // A confirmed post means we're back online.
      await repository.postLead(order);
      expect(repository.offline.value, isFalse);
    },
  );

  test('a refresh moves stored leads off the search ZIP once', () async {
    final log = <Uri>[];
    final repository = LeadRepository(
      local: store,
      community: FakeCommunity(),
      pipeline: ListingPipeline(
        gemini: GeminiService(apiKey: ''),
        sources: [
          CraigslistSource(
            fetcher: ListingFetchService(
              client: fakeInternet(log: log),
              maxAttempts: 1,
              policy: RequestPolicy.unthrottled,
            ),
          ),
        ],
        geocoder: testGeocoder(),
      ),
      autoRefreshInterval: null,
    )..start();
    addTearDown(repository.dispose);
    // Saved before postings were placed by their map point.
    final saved = order.copyWith(
      id: 'cl-aaa111',
      zipCode: '94110',
      source: LeadSource.scraped,
      isFavorite: true,
      createdAt: DateTime.now(),
    );
    await store.upsertAll([
      saved.copyWith(
        sourceUrl: 'https://www.craigslist.org/view/d/oakland/aaa111',
      ),
      saved.copyWith(
        id: 'cl-bbb222',
        isFavorite: false,
        sourceUrl: 'https://www.craigslist.org/view/d/sf/bbb222',
      ),
    ]);
    await store.markRejected({'cl-ccc333'});
    await Future<void>.delayed(Duration.zero);
    repository.profile.value = const SearchProfile(
      profession: 'plumber',
      zipCode: '94110',
    );

    await repository.refresh();
    expect(store.get('cl-aaa111')!.zipCode, '94609');
    expect(store.get('cl-aaa111')!.isFavorite, isTrue);
    expect(store.get('cl-bbb222')!.zipCode, '94110', reason: 'no map point');
    expect(log.where((uri) => uri.path.contains('/view/')), hasLength(2));

    // Each posting is reread once per run of the app.
    await Future<void>.delayed(Duration.zero);
    log.clear();
    await repository.refresh();
    expect(log.where((uri) => uri.path.contains('/view/')), isEmpty);
  });

  test('saving a profile backs it up and restores it', () async {
    final community = FakeCommunity();
    final repository = repo(community);
    const next = SearchProfile(profession: 'hvac', zipCode: '10002');
    await repository.updateProfile(next);
    expect(community.savedProfiles, [next]);
    expect(await repository.remoteProfile(), next);
    expect(store.searchProfile, next);
  });

  test('disposing mid-refresh is safe and closes the sources', () async {
    final gate = Completer<void>();
    final source = SlowSource(gate.future);
    final repository = LeadRepository(
      local: store,
      community: FakeCommunity(),
      pipeline: ListingPipeline(
        gemini: GeminiService(apiKey: ''),
        sources: [source],
      ),
      autoRefreshInterval: null,
    )..start();
    repository.profile.value = const SearchProfile(
      profession: 'plumber',
      zipCode: '10001',
    );

    final refresh = repository.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(repository.status.value.isRunning, isTrue);
    repository.dispose();
    expect(source.closed, isTrue);
    gate.complete();
    await refresh; // Must not touch the disposed notifiers.
    expect(repository.isDisposed, isTrue);
    repository.dispose(); // Idempotent.
  });

  test('community and legacy leads are graded on the way to the UI', () async {
    final repository = repo(FakeCommunity())..start();
    addTearDown(repository.dispose);
    await store.upsert(
      order.copyWith(
        id: 'legacy',
        description: 'Send a deposit by gift card and text me on WhatsApp.',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final graded = repository.leads.value.single;
    expect(graded.trust, LeadTrust.spam);
    expect(store.get('legacy')!.trust, isNull, reason: 'grade not persisted');
  });
}

/// A source whose search waits on [gate].
class SlowSource extends ListingSource {
  SlowSource(this.gate);

  final Future<void> gate;
  var closed = false;

  @override
  String get id => 'slow';

  @override
  String get label => 'Slow';

  @override
  String get idPrefix => 'sl-';

  @override
  HostStatus get status =>
      const HostStatus(requestsLastHour: 0, hourlyLimit: 1);

  @override
  Future<List<RawListing>> search(SearchProfile profile) async {
    await gate;
    return const [];
  }

  @override
  Future<List<RawListing>> fetchDetails(List<RawListing> listings) async =>
      listings;

  @override
  void close() => closed = true;
}
