import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_leads/models/search_profile.dart';
import 'package:free_leads/sources/craigslist_source.dart';
import 'package:free_leads/sources/listing_fetch_service.dart';
import 'package:free_leads/sources/request_policy.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final searchHtml = File('test/fixtures/craigslist_search.html')
      .readAsStringSync();
  final postingHtml = File('test/fixtures/craigslist_posting.html')
      .readAsStringSync();

  test('search URL uses ZIP + radius so Craigslist picks the city', () {
    final uri = CraigslistSource.searchUri(
      category: 'ggg',
      zipCode: '94110',
      radiusMiles: 25,
      query: ' plumber ',
    );
    expect(
      uri.toString(),
      'https://www.craigslist.org/search?cat=ggg&postal=94110&radius=25&query=plumber',
    );
  });

  test('parses static search results', () {
    final listings = parseCraigslistSearch(
      CraigslistSearchPage(searchHtml, '94110'),
    );
    expect(listings, hasLength(3));

    final first = listings.first;
    expect(first.id, 'cl-aaa111');
    expect(first.title, 'Need plumber for leaking water heater');
    expect(first.neighborhood, 'oakland north / temescal');
    expect(first.priceText, isNull, reason: r'"$0" means no amount given');
    expect(first.searchZip, '94110');
    expect(
      first.url.toString(),
      'https://www.craigslist.org/view/d/oakland-need-plumber-for-leaking/aaa111',
    );
    expect(listings[1].priceText, r'$1,200');
  });

  test('parses posting body, compensation and time', () {
    final details = parseCraigslistPosting(postingHtml);
    expect(details.title, 'Need plumber for leaking water heater');
    expect(details.compensation, r'$85/hr');
    expect(
      details.body,
      'Our 40 gallon water heater is leaking from the bottom.\n\n'
      'Need someone licensed this week. Call or text 510-555-0142.',
    );
    expect(details.body, isNot(contains('QR Code')));
    expect(details.postedAt, DateTime.utc(2026, 10, 14, 16, 15));
    expect(details.latitude, 37.8341);
    expect(details.longitude, -122.2637);
  });

  test('reads the map point from the geo tag, and ignores a blank one', () {
    final tagged = parseCraigslistPosting(
      '<html><head><meta name="geo.position" content="40.023600;-75.329500">'
      '</head><body></body></html>',
    );
    expect(tagged.latitude, 40.0236);
    expect(tagged.longitude, -75.3295);

    final blank = parseCraigslistPosting(
      '<div id="map" data-latitude="0" data-longitude="0"></div>',
    );
    expect(blank.latitude, isNull);
    expect(blank.longitude, isNull);
    expect(parseCraigslistPosting('<p>no map</p>').latitude, isNull);
  });

  test('parses Craigslist offsets with and without a colon', () {
    expect(
      parseCraigslistTime('2026-09-08T19:26:51-0400'),
      DateTime.utc(2026, 9, 8, 23, 26, 51),
    );
    expect(
      parseCraigslistTime('2026-09-08T19:26:51-04:00'),
      DateTime.utc(2026, 9, 8, 23, 26, 51),
    );
  });

  test('profiles search gigs and jobs by default', () {
    const profile = SearchProfile(profession: 'plumber', zipCode: '94110');
    expect(profile.boardCategories, ['ggg', 'jjj']);
    expect(
      SearchProfile.fromJson({'profession': 'plumber', 'zipCode': '94110'})
          .boardCategories,
      ['ggg', 'jjj'],
    );
    expect(
      SearchProfile.fromJson({
        'profession': 'plumber',
        'zipCode': '94110',
        'boardCategories': ['ggg'],
      }).boardCategories,
      ['ggg', 'jjj'],
      reason: 'profiles saved before jobs were added are upgraded',
    );
  });

  test('searches the gigs and jobs boards and merges duplicates', () async {
    final categories = <String?>[];
    final source = CraigslistSource(
      fetcher: ListingFetchService(
        client: MockClient((request) async {
          categories.add(request.url.queryParameters['cat']);
          return http.Response(searchHtml, 200);
        }),
        policy: RequestPolicy.unthrottled,
        maxAttempts: 1,
      ),
    );
    addTearDown(source.close);

    final listings = await source.search(
      const SearchProfile(profession: 'plumber', zipCode: '94110'),
    );
    expect(categories, ['ggg', 'jjj']);
    expect(listings, hasLength(3), reason: 'a cross-post is listed once');
  });

  test('jobs are interleaved with gigs, not queued behind them', () async {
    String page(String board, int count) =>
        '''
<ol class="cl-static-search-results">
  ${[for (var i = 0; i < count; i++) '<li class="cl-static-search-result" title="t"><a href="https://sfbay.craigslist.org/x/d/$board-$i/$board$i"><div class="title">$board job $i</div></a></li>'].join()}
</ol>''';
    final source = CraigslistSource(
      fetcher: ListingFetchService(
        client: MockClient((request) async {
          final cat = request.url.queryParameters['cat']!;
          return http.Response(page(cat, cat == 'ggg' ? 3 : 2), 200);
        }),
        policy: RequestPolicy.unthrottled,
        maxAttempts: 1,
      ),
    );
    addTearDown(source.close);

    final listings = await source.search(
      const SearchProfile(profession: 'plumber', zipCode: '94110'),
    );
    expect(listings.map((listing) => listing.id), [
      'cl-ggg0',
      'cl-jjj0',
      'cl-ggg1',
      'cl-jjj1',
      'cl-ggg2',
    ]);
  });
}
