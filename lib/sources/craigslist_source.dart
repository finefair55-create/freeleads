import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../models/raw_listing.dart';
import '../models/search_profile.dart';
import 'listing_fetch_service.dart';
import 'listing_source.dart';
import 'request_policy.dart';

/// Searches Craigslist from the device by ZIP + radius and reads posting
/// pages. Craigslist resolves the ZIP to the right city itself, so no site
/// directory is needed. Each of the profile's board categories (gigs `ggg`,
/// jobs `jjj`) is one search:
/// `https://www.craigslist.org/search?cat=ggg&postal=94110&radius=25&query=plumber`
/// redirects to `/search/city/san-francisco-ca?...`.
///
/// Parsing relies on the no-JS fallback markup Craigslist serves to every
/// client (`ol.cl-static-search-results` and `#postingbody`).
class CraigslistSource extends ListingSource {
  CraigslistSource({
    ListingFetchService? fetcher,
    HostCooldownStore? cooldowns,
    this.detailConcurrency = 2,
  }) : _fetcher =
           fetcher ??
           ListingFetchService(siteName: 'Craigslist', cooldowns: cooldowns);

  static const host = 'www.craigslist.org';

  final ListingFetchService _fetcher;

  /// Posting pages read in parallel. The fetcher still spaces requests to
  /// the host, so this only overlaps waiting on the network.
  final int detailConcurrency;

  @override
  String get id => 'craigslist';

  @override
  String get label => 'Craigslist';

  @override
  String get idPrefix => 'cl-';

  @override
  HostStatus get status => _fetcher.statusFor(host);

  @override
  void close() => _fetcher.close();

  static Uri searchUri({
    required String category,
    required String zipCode,
    required int radiusMiles,
    required String query,
  }) {
    return Uri.https(host, '/search', {
      'cat': category,
      'postal': zipCode,
      'radius': '$radiusMiles',
      if (query.trim().isNotEmpty) 'query': query.trim(),
    });
  }

  /// Returns de-duplicated search hits across the profile's board categories
  /// (summary fields only; call [fetchDetails] for bodies). Categories are
  /// interleaved so a busy gigs board can't crowd jobs out of the
  /// pipeline's per-refresh cap.
  @override
  Future<List<RawListing>> search(SearchProfile profile) async {
    final pages = <List<RawListing>>[];
    Object? firstError;
    for (final category in profile.boardCategories) {
      final uri = searchUri(
        category: category,
        zipCode: profile.zipCode,
        radiusMiles: profile.radiusMiles,
        query: profile.profession,
      );
      try {
        final html = await _fetcher.fetchRaw(uri);
        final parsed = await compute(
          parseCraigslistSearch,
          CraigslistSearchPage(html, profile.zipCode),
        );
        pages.add(parsed);
      } on ListingFetchException catch (error) {
        debugPrint('Craigslist search failed for $uri: $error');
        firstError ??= error;
        if (error.isPaused) {
          break;
        }
      } catch (error) {
        debugPrint('Craigslist search failed for $uri: $error');
        firstError ??= error;
      }
    }
    final seen = <String>{};
    final results = <RawListing>[];
    for (var i = 0; pages.any((page) => i < page.length); i++) {
      for (final page in pages) {
        if (i < page.length && seen.add(page[i].id)) {
          results.add(page[i]);
        }
      }
    }
    if (results.isEmpty && firstError != null) {
      throw firstError;
    }
    return results;
  }

  /// Fills in body, compensation and post time for each listing. A listing
  /// whose page fails to load is returned with its summary fields only, and
  /// a block stops all workers so the paused host isn't hit again.
  @override
  Future<List<RawListing>> fetchDetails(List<RawListing> listings) async {
    final output = List<RawListing>.of(listings);
    var next = 0;
    var stop = false;
    Future<void> worker() async {
      while (!stop && next < listings.length) {
        final index = next++;
        final listing = listings[index];
        try {
          final html = await _fetcher.fetchRaw(listing.url);
          final details = await compute(parseCraigslistPosting, html);
          output[index] = listing.withDetails(
            title: details.title,
            body: details.body,
            compensation: details.compensation,
            postedAt: details.postedAt,
            latitude: details.latitude,
            longitude: details.longitude,
          );
        } on ListingFetchException catch (error) {
          debugPrint('Craigslist posting failed for ${listing.url}: $error');
          if (error.isPaused) {
            stop = true;
          }
        } catch (error) {
          debugPrint('Craigslist posting failed for ${listing.url}: $error');
        }
      }
    }

    await Future.wait(
      List.generate(
        detailConcurrency.clamp(1, listings.isEmpty ? 1 : listings.length),
        (_) => worker(),
      ),
    );
    return output;
  }
}

class CraigslistSearchPage {
  const CraigslistSearchPage(this.html, this.searchZip);
  final String html;
  final String searchZip;
}

/// Top-level so it can run in a background isolate via [compute].
List<RawListing> parseCraigslistSearch(CraigslistSearchPage page) {
  final document = html_parser.parse(page.html);
  final listings = <RawListing>[];
  for (final item in document.querySelectorAll('li.cl-static-search-result')) {
    final href = item.querySelector('a')?.attributes['href'];
    if (href == null) {
      continue;
    }
    final url = Uri.tryParse(href);
    if (url == null || url.pathSegments.isEmpty) {
      continue;
    }
    final title =
        _text(item.querySelector('.title')) ?? item.attributes['title'] ?? '';
    if (title.isEmpty) {
      continue;
    }
    final price = _text(item.querySelector('.price'));
    listings.add(
      RawListing(
        id: 'cl-${url.pathSegments.last}',
        board: 'craigslist',
        url: url.hasScheme ? url : Uri.https(CraigslistSource.host, href),
        title: title,
        searchZip: page.searchZip,
        // Gig boards show "$0" when no amount was entered.
        priceText: price == null || price == r'$0' ? null : price,
        neighborhood: _text(item.querySelector('.location')),
      ),
    );
  }
  return listings;
}

class CraigslistPostingDetails {
  const CraigslistPostingDetails({
    this.title,
    this.body,
    this.compensation,
    this.postedAt,
    this.latitude,
    this.longitude,
  });

  final String? title;
  final String? body;
  final String? compensation;
  final DateTime? postedAt;

  /// The posting's map point; Craigslist rarely states a ZIP.
  final double? latitude;
  final double? longitude;
}

/// Top-level so it can run in a background isolate via [compute].
CraigslistPostingDetails parseCraigslistPosting(String html) {
  final document = html_parser.parse(html);

  final bodyElement = document.querySelector('#postingbody');
  String? body;
  if (bodyElement != null) {
    bodyElement
        .querySelectorAll('.print-information')
        .forEach((node) => node.remove());
    for (final br in bodyElement.querySelectorAll('br')) {
      br.replaceWith(dom.Text('\n'));
    }
    body = bodyElement.text
        .split('\n')
        .map((line) => line.trim())
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  String? compensation;
  for (final attr in document.querySelectorAll('.attrgroup .attr')) {
    final label = _text(attr.querySelector('.labl'))?.toLowerCase() ?? '';
    if (label.startsWith('compensation')) {
      compensation = _text(attr.querySelector('.valu'));
    }
  }

  final datetime = document
      .querySelector('.postinginfos time[datetime], time.date[datetime]')
      ?.attributes['datetime'];

  // The posting map (`#map[data-latitude]`), else the geo meta tag
  // (`40.0236;-75.3295`).
  final map = document.querySelector('#map');
  var lat = double.tryParse(map?.attributes['data-latitude'] ?? '');
  var lng = double.tryParse(map?.attributes['data-longitude'] ?? '');
  if (lat == null || lng == null) {
    final geo = document
        .querySelector('meta[name="geo.position"]')
        ?.attributes['content']
        ?.split(';');
    if (geo != null && geo.length == 2) {
      lat = double.tryParse(geo[0].trim());
      lng = double.tryParse(geo[1].trim());
    }
  }
  final located =
      lat != null &&
      lng != null &&
      lat.abs() <= 90 &&
      lng.abs() <= 180 &&
      (lat != 0 || lng != 0);

  return CraigslistPostingDetails(
    latitude: located ? lat : null,
    longitude: located ? lng : null,
    title:
        _text(document.querySelector('.postingtitletext #titletextonly')) ??
        _text(document.querySelector('.postingtitletext')),
    body: body == null || body.isEmpty ? null : body,
    compensation: compensation,
    postedAt: datetime == null ? null : parseCraigslistTime(datetime),
  );
}

/// Craigslist emits offsets without a colon (`2026-09-08T19:26:51-0400`),
/// which [DateTime.parse] accepts; this guards against variants it doesn't.
DateTime? parseCraigslistTime(String value) {
  final direct = DateTime.tryParse(value);
  if (direct != null) {
    return direct;
  }
  final fixed = value.replaceFirstMapped(
    RegExp(r'([+-]\d{2})(\d{2})$'),
    (m) => '${m[1]}:${m[2]}',
  );
  return DateTime.tryParse(fixed);
}

String? _text(dom.Element? element) {
  final text = element?.text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text == null || text.isEmpty ? null : text;
}
