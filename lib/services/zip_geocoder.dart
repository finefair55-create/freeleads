import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../models/lead.dart';

/// Offline ZIP → map point lookup backed by the bundled US Census ZCTA
/// gazetteer (`assets/zip_centroids.csv`, public domain). Leads only carry a
/// ZIP, so the map places them at that ZIP's internal point, with no
/// geocoding API, key, or network round-trip.
class ZipGeocoder {
  ZipGeocoder({AssetBundle? bundle, this.assetPath = defaultAsset})
    // ignore: prefer_initializing_formals
    : _bundle = bundle;

  /// A table that is loaded from the start, e.g. a small one for tests.
  @visibleForTesting
  ZipGeocoder.fromPoints(Map<String, LatLng> points)
    : _bundle = null,
      assetPath = defaultAsset,
      _points = points;

  static const defaultAsset = 'assets/zip_centroids.csv';

  /// Shared instance so the table is parsed once per app run.
  static final instance = ZipGeocoder();

  /// Geographic center of the contiguous US, used when nothing is known.
  static const usCenter = LatLng(39.83, -98.58);

  final AssetBundle? _bundle;
  final String assetPath;

  Map<String, LatLng>? _points;
  Future<void>? _loading;

  bool get isLoaded => _points != null;

  /// Loads and parses the table (off the UI isolate). Safe to call often;
  /// after a failure, the next call tries again.
  Future<void> ensureLoaded() {
    if (_points != null) {
      return Future.value();
    }
    return _loading ??= () async {
      try {
        final csv = await (_bundle ?? rootBundle).loadString(assetPath);
        _points = await compute(parse, csv);
      } catch (_) {
        _loading = null;
        rethrow;
      }
    }();
  }

  /// Point for [zip], or null when unknown or not loaded yet.
  LatLng? lookup(String? zip) {
    final normalized = Lead.normalizeZip(zip);
    return normalized == null ? null : _points?[normalized];
  }

  /// The ZIP whose center lies nearest [point], or null when none is within
  /// [maxKm] (e.g. a point offshore or abroad) or the table isn't loaded.
  /// Boards place a posting by coordinates rather than ZIP; this puts the
  /// lead in its real town instead of the search's center.
  String? nearestZip(LatLng point, {double maxKm = 40}) {
    final points = _points;
    if (points == null) {
      return null;
    }
    // Equirectangular distance is plenty at this scale, and cheap enough
    // to scan the whole table.
    final cosLat = math.cos(point.latitude * math.pi / 180);
    String? best;
    var bestSq = double.infinity;
    for (final MapEntry(key: zip, value: center) in points.entries) {
      final dLat = center.latitude - point.latitude;
      final dLng = (center.longitude - point.longitude) * cosLat;
      final sq = dLat * dLat + dLng * dLng;
      if (sq < bestSq) {
        bestSq = sq;
        best = zip;
      }
    }
    return math.sqrt(bestSq) * 111.32 <= maxKm ? best : null;
  }

  /// Parses `zip,lat,lng` lines; `#` lines are comments.
  static Map<String, LatLng> parse(String csv) {
    final points = <String, LatLng>{};
    for (final line in const LineSplitter().convert(csv)) {
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      final parts = line.split(',');
      if (parts.length < 3) {
        continue;
      }
      final lat = double.tryParse(parts[1]);
      final lng = double.tryParse(parts[2]);
      if (lat != null && lng != null) {
        points[parts[0]] = LatLng(lat, lng);
      }
    }
    return points;
  }
}

/// A lead's position on the map. Leads only carry a ZIP, so the pin sits at
/// [zipCenter]; leads sharing a ZIP sit on the same spot and are shown as
/// one [LeadCluster].
class LeadPin {
  const LeadPin({required this.lead, required this.zipCenter});

  final Lead lead;
  final LatLng zipCenter;
}

/// Places one pin per lead, at its ZIP's center, in drawing order:
/// community orders and saved leads last, so they sit on top.
///
/// Leads whose ZIP is missing or unknown are counted in [unmapped] instead
/// of being guessed onto the map. With an [area], leads whose ZIP lies
/// farther than [areaMiles] from it are counted in [outside]: a ZIP that
/// far from the search is almost always misread from the listing (or left
/// from an earlier search), and pinning it would scatter stray pins across
/// the country.
({List<LeadPin> pins, int unmapped, int outside}) placeLeadPins(
  Iterable<Lead> leads,
  ZipGeocoder geocoder, {
  LatLng? area,
  double? areaMiles,
}) {
  const distance = Distance();
  final maxMeters = areaMiles == null ? null : areaMiles * 1609.34;
  final pins = <LeadPin>[];
  var unmapped = 0;
  var outside = 0;
  for (final lead in leads) {
    final point = geocoder.lookup(lead.zipCode);
    if (point == null) {
      unmapped++;
      continue;
    }
    if (area != null &&
        maxMeters != null &&
        distance(area, point) > maxMeters) {
      outside++;
      continue;
    }
    pins.add(LeadPin(lead: lead, zipCenter: point));
  }
  int rank(Lead lead) =>
      (lead.isFavorite ? 2 : 0) + (lead.source == LeadSource.internal ? 1 : 0);
  pins.sort((a, b) {
    final byRank = rank(a.lead).compareTo(rank(b.lead));
    return byRank != 0 ? byRank : a.lead.id.compareTo(b.lead.id);
  });
  return (pins: pins, unmapped: unmapped, outside: outside);
}

/// Leads close enough on screen to share one marker: a pin when it's a
/// single lead, a count badge otherwise.
class LeadCluster {
  const LeadCluster({required this.point, required this.pins});

  /// Mean of the leads' ZIP centers; exactly the spot when they share one.
  final LatLng point;
  final List<LeadPin> pins;

  /// Stable across rebuilds for the same set of leads.
  String get key => (pins.map((p) => p.lead.id).toList()..sort()).join(',');

  List<LatLng> get zipCenters =>
      {for (final pin in pins) pin.zipCenter}.toList();

  /// All its leads share one spot, so zooming in won't pull them apart.
  bool get sameSpot => zipCenters.length == 1;
}

/// The zoom [clusterLeadPins] groups for at [zoom]: rounded down to a half
/// level, so clusters change only twice per zoom level, and zooming in
/// from there only spreads them further apart.
double clusterLevel(double zoom) => (zoom * 2).floor() / 2;

/// Groups [pins] into [LeadCluster]s so no two markers cover each other:
/// each cluster takes every pin whose ZIP lies within [radiusPx] screen
/// pixels of the cluster's first ZIP at [clusterLevel] of [zoom]. Leads
/// sharing a ZIP always share a cluster. The grouping depends only on the
/// pins' ZIPs and ids, not on feed order.
List<LeadCluster> clusterLeadPins(
  Iterable<LeadPin> pins, {
  required double zoom,
  double radiusPx = 72,
}) {
  final worldPx = 256 * math.pow(2, clusterLevel(zoom));
  // Web-Mercator pixel position at this zoom.
  math.Point<double> project(LatLng p) {
    final sin = math.sin(p.latitude * math.pi / 180);
    return math.Point(
      (p.longitude + 180) / 360 * worldPx,
      (0.5 - math.log((1 + sin) / (1 - sin)) / (4 * math.pi)) * worldPx,
    );
  }

  final ordered = pins.toList()
    ..sort((a, b) {
      final byLat = a.zipCenter.latitude.compareTo(b.zipCenter.latitude);
      if (byLat != 0) return byLat;
      final byLng = a.zipCenter.longitude.compareTo(b.zipCenter.longitude);
      return byLng != 0 ? byLng : a.lead.id.compareTo(b.lead.id);
    });
  final seeds = <math.Point<double>>[];
  final groups = <List<LeadPin>>[];
  for (final pin in ordered) {
    final at = project(pin.zipCenter);
    final i = seeds.indexWhere((seed) => seed.distanceTo(at) <= radiusPx);
    if (i == -1) {
      seeds.add(at);
      groups.add([pin]);
    } else {
      groups[i].add(pin);
    }
  }
  LatLng middle(List<LeadPin> group) {
    final centers = {for (final pin in group) pin.zipCenter};
    if (centers.length == 1) {
      return centers.single;
    }
    return LatLng(
      group.map((p) => p.zipCenter.latitude).reduce((a, b) => a + b) /
          group.length,
      group.map((p) => p.zipCenter.longitude).reduce((a, b) => a + b) /
          group.length,
    );
  }

  return [
    for (final group in groups) LeadCluster(point: middle(group), pins: group),
  ];
}
