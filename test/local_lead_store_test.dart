import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_leads/models/lead.dart';
import 'package:free_leads/models/search_profile.dart';
import 'package:free_leads/services/local_lead_store.dart';
import 'package:hive_ce/hive_ce.dart';

Lead lead(
  String id, {
  DateTime? postedAt,
  LeadSource source = LeadSource.scraped,
}) => Lead(
  id: id,
  title: 'Lead $id',
  description: 'Description $id',
  category: 'Plumbing',
  location: 'Oakland',
  zipCode: '94609',
  source: source,
  createdAt: postedAt ?? DateTime.now(),
  postedAt: postedAt,
);

void main() {
  late Directory dir;
  late LocalLeadStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('free_leads_hive_');
    store = await LocalLeadStore.open(path: dir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('persists leads across reopen, newest first', () async {
    await store.upsertAll([
      lead('a', postedAt: DateTime(2026, 10, 1)),
      lead('b', postedAt: DateTime(2026, 10, 3)),
    ]);
    await Hive.close();
    store = await LocalLeadStore.open(path: dir.path);
    expect(store.all.map((l) => l.id), ['b', 'a']);
  });

  test('re-scraping a lead keeps it favorited', () async {
    await store.upsert(lead('a'));
    await store.setFavorite(store.get('a')!, true);
    await store.upsert(lead('a'));
    expect(store.get('a')!.isFavorite, isTrue);
  });

  test('favoriting a lead not stored yet saves a copy', () async {
    await store.setFavorite(
      lead('community-1', source: LeadSource.internal),
      true,
    );
    expect(store.get('community-1')!.isFavorite, isTrue);
  });

  test(
    'prune drops old scraped leads but keeps favorites and own posts',
    () async {
      final old = DateTime.now().subtract(const Duration(days: 40));
      await store.upsertAll([
        lead('old', postedAt: old),
        lead('old-fav', postedAt: old).copyWith(isFavorite: true),
        lead('old-post', postedAt: old, source: LeadSource.internal),
        lead('new'),
      ]);
      await store.markRejected(['spam']);
      final removed = await store.prune(const Duration(days: 21));
      expect(removed, 1);
      expect(store.ids, {'old-fav', 'old-post', 'new'});
      expect(store.rejectedIds, {'spam'});
    },
  );

  test('stores search profile and Gemini key', () async {
    const profile = SearchProfile(
      profession: 'electrician',
      zipCode: '10001',
      radiusMiles: 10,
    );
    await store.saveSearchProfile(profile);
    await store.saveGeminiApiKey('  abc  ');
    expect(store.searchProfile, profile);
    expect(store.geminiApiKey, 'abc');
    await store.saveGeminiApiKey('');
    expect(store.geminiApiKey, isNull);
  });

  test('watch emits current data then coalesced updates', () async {
    final emissions = <List<String>>[];
    final sub = store.watch().listen(
      (leads) => emissions.add(leads.map((l) => l.id).toList()),
    );
    await Future<void>.delayed(Duration.zero);
    await store.upsertAll([lead('a'), lead('b')]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();
    expect(emissions.first, isEmpty);
    expect(emissions.last.toSet(), {'a', 'b'});
    expect(emissions.length, lessThanOrEqualTo(3));
  });

  test('prune drops stale copies of others\' orders, never your own', () async {
    final old = DateTime.now().subtract(const Duration(days: 40));
    Lead order(String id, String? author) => lead(
      id,
      postedAt: old,
      source: LeadSource.internal,
    ).copyWith(authorId: author);
    await store.upsertAll([
      order('theirs', 'someone-else'),
      order('mine', 'me'),
      order('local-1', null),
    ]);

    // Without knowing who "me" is, nothing internal is touched.
    expect(await store.prune(const Duration(days: 21)), 0);
    expect(await store.prune(const Duration(days: 21), myUid: 'me'), 1);
    expect(store.ids, {'mine', 'local-1'});
  });

  test('prune caps stored leads and rejected ids, oldest first', () async {
    final now = DateTime.now();
    await store.upsertAll([
      for (var i = 0; i < 6; i++)
        lead('cl-$i', postedAt: now.subtract(Duration(hours: i))),
    ]);
    await store.setFavorite(store.get('cl-5')!, true);
    await store.markRejected(['r1', 'r2', 'r3']);

    final removed = await store.prune(
      const Duration(days: 21),
      maxLeads: 3,
      maxRejected: 2,
    );
    expect(removed, 2);
    expect(store.ids, {'cl-0', 'cl-1', 'cl-2', 'cl-5'}, reason: 'saved kept');
    expect(store.rejectedIds, hasLength(2));
    await store.compact();
    expect(store.ids, hasLength(4));
  });

  test('remembers host pauses and the spam filter', () async {
    final until = DateTime.utc(2026, 10, 16, 12);
    await store.saveCooldown('www.craigslist.org', until);
    await store.saveHideSpam(true);
    expect(store.cooldownUntil('www.craigslist.org'), until);
    expect(store.hideSpam, isTrue);
    await store.saveCooldown('www.craigslist.org', null);
    expect(store.cooldownUntil('www.craigslist.org'), isNull);
  });
}
