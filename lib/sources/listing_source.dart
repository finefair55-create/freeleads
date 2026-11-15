import 'package:flutter/foundation.dart';

import '../models/raw_listing.dart';
import '../models/search_profile.dart';
import 'listing_fetch_service.dart';

/// A site FreeLeads can search for job requests.
///
/// To add one, implement this interface (usually with its own
/// [ListingFetchService], so it gets its own rate limits and pauses), give
/// it a unique [id] and [idPrefix], and add it to
/// `ListingPipeline.defaultSources`. The pipeline searches every source,
/// merges and de-duplicates the hits, and sends them through the same
/// Gemini review and trust grading.
abstract class ListingSource {
  /// Stable id stored on leads as `Lead.board`, e.g. `craigslist`.
  String get id;

  /// Name shown on source badges, e.g. "Craigslist".
  String get label;

  /// Prefix of every [RawListing.id] from this source, e.g. `cl-`, so ids
  /// never collide across sources.
  String get idPrefix;

  /// Whether the source can run on this platform.
  bool get isSupported => !kIsWeb;

  /// Search hits for [profile] (summary fields only).
  Future<List<RawListing>> search(SearchProfile profile);

  /// Fills in body, pay and post time. A listing whose page fails to load
  /// is returned unchanged.
  Future<List<RawListing>> fetchDetails(List<RawListing> listings);

  /// Rate limit and pause state, for the Profile tab.
  HostStatus get status;

  /// Releases HTTP connections. The source can't be used afterwards.
  void close();
}

/// Badge labels for stored board ids, including sources that are no longer
/// registered, so old leads still show where they came from.
String boardLabel(String? board) => switch (board) {
  null => '',
  'craigslist' => 'Craigslist',
  _ => board.isEmpty ? '' : '${board[0].toUpperCase()}${board.substring(1)}',
};
