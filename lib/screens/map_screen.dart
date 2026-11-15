import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../app_scope.dart';
import '../models/lead.dart';
import '../models/search_profile.dart';
import '../services/lead_repository.dart';
import '../services/zip_geocoder.dart';
import '../theme/app_theme.dart';
import '../widgets/format.dart';
import '../widgets/lead_badges.dart';
import '../widgets/lead_details_sheet.dart';
import '../widgets/reply_button.dart';
import '../widgets/safe_async.dart';
import '../widgets/skeleton.dart';

/// Leads on OpenStreetMap tiles. Each lead sits at its ZIP's center (see
/// [placeLeadPins]); leads that would cover each other on screen merge into
/// one count badge (see [clusterLeadPins]), so markers never pile up. A
/// lone lead shows as a pin, and a tap previews it in a floating card. A
/// badge's tap zooms in until its leads separate, or, when they share one
/// ZIP and never will, lists them in a sheet. A metro view shows a marker
/// per town or neighborhood; only zoomed out past [pinZoom] (several
/// states) do leads merge into larger regional counts.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, this.geocoder, this.tileProvider, this.focus});

  /// Defaults to [ZipGeocoder.instance].
  final ZipGeocoder? geocoder;

  /// Requests from other tabs to fly to a lead and preview it.
  final MapFocus? focus;

  /// Overridable so widget tests don't hit the tile server.
  final TileProvider? tileProvider;

  /// Lowest zoom that shows leads town by town: a whole state on a phone.
  /// Below it (several states or the country), leads merge into regional
  /// count markers.
  static const pinZoom = 6.0;

  /// From this zoom, a badge's tap lists its leads instead of zooming in
  /// further: ZIPs this close together are as apart as they will get.
  static const listZoom = 15.0;

  /// OpenStreetMap's tile policy asks apps to identify themselves.
  static const userAgentPackageName = 'com.example.free_leads';

  @override
  State<MapScreen> createState() => _MapScreenState();
}

/// Asks the [MapScreen] to show one lead, e.g. from a feed card's Show on
/// map. The request waits until the map has loaded, so it works on a map
/// tab that hasn't been opened yet.
class MapFocus extends ChangeNotifier {
  String? _leadId;

  void show(Lead lead) {
    _leadId = lead.id;
    notifyListeners();
  }

  String? _take() {
    final id = _leadId;
    _leadId = null;
    return id;
  }
}

class _MapScreenState extends State<MapScreen>
    with SingleTickerProviderStateMixin {
  final _controller = MapController();
  late final ZipGeocoder _geocoder = widget.geocoder ?? ZipGeocoder.instance;
  Object? _loadError;
  bool _mapReady = false;
  ValueNotifier<SearchProfile?>? _profile;

  /// Search area the camera was last fitted to (see [_areaKey]).
  String? _centeredOn;

  /// Zoom the markers were clustered for. Refreshed only when the camera
  /// crosses a [clusterLevel], so panning and zooming within one rebuild
  /// nothing.
  double? _layoutZoom;

  /// The camera's first position; built once, since the user (and
  /// [_recenter]) own the camera afterwards.
  MapOptions? _options;

  /// Visible leads, pins and clusters from the last build, reused until
  /// the leads, spam filter, search area or whole zoom level change.
  _PinLayout? _pinLayout;
  ({List<Lead> all, bool hideSpam, List<Lead> visible})? _visibleLeads;
  ({List<LeadCluster> clusters, List<LeadPin> pins, double zoom})?
  _clusterLayout;

  /// Set while map tiles are failing to load (offline / weak signal).
  bool _tilesFailing = false;
  Timer? _tileErrorTimer;

  /// The lead in the preview card, if any.
  String? _previewId;

  /// Drives [_flyTo]'s camera moves.
  late final AnimationController _flight = AnimationController(
    vsync: this,
    duration: AppTheme.motionSlow,
  );
  VoidCallback? _flightStep;

  /// Neighborhood zoom for Show on map: nearby ZIPs show apart.
  static const _focusZoom = 13.0;

  /// Shows lead [id] in the preview card. [focus] is the tapped marker,
  /// which the camera keeps clear of the card.
  void _preview(String? id, {LatLng? focus}) {
    setState(() => _previewId = id);
    if (focus != null) {
      _keepClearOfPreview(focus);
    }
  }

  /// Room the preview card and the attribution button take at the bottom.
  static const _previewClearance = 340.0;

  /// Pans just enough that the marker at [point] isn't hidden under the
  /// preview card (or the legend at the top).
  void _keepClearOfPreview(LatLng point) {
    final camera = _controller.camera;
    final center = _centerClearOfPreview(camera, point);
    if (center != null) {
      _flyTo(center, camera.zoom);
    }
  }

  /// Where [camera] should center so [point] shows above the preview card
  /// and below the legend, or null if it already does.
  static LatLng? _centerClearOfPreview(MapCamera camera, LatLng point) {
    final offset = camera.latLngToScreenOffset(point);
    final bottom = camera.size.height - _previewClearance;
    if (bottom <= 0 || (offset.dy >= 100 && offset.dy <= bottom)) {
      return null;
    }
    final target = math.max(100.0, bottom * 0.6);
    final center = camera.size.center(Offset.zero);
    return camera.screenOffsetToLatLng(center + Offset(0, offset.dy - target));
  }

  /// Handles a pending [MapScreen.focus] request once the map is ready:
  /// flies in to the lead's pin and previews it.
  void _onFocusRequest() {
    if (!_mapReady || !mounted) {
      return;
    }
    final id = widget.focus?._take();
    if (id == null) {
      return;
    }
    final repository = AppScope.of(context).repository;
    final leads = _visible(repository);
    final profile = repository.profile.value;
    final pin = _layoutPins(
      leads,
      _geocoder.lookup(profile?.zipCode),
      _areaMiles(profile),
    ).pins.where((pin) => pin.lead.id == id).firstOrNull;
    if (pin == null) {
      final lead = leads.where((l) => l.id == id).firstOrNull;
      final known = _geocoder.lookup(lead?.zipCode) != null;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            known
                ? "This lead's ZIP is far outside your search area, so it "
                      "isn't on the map."
                : "This lead's ZIP isn't on the map.",
          ),
        ),
      );
      return;
    }
    setState(() => _previewId = id);
    final zoom = math.max(_controller.camera.zoom, _focusZoom);
    final point = pin.zipCenter;
    final target = _controller.camera.withPosition(center: point, zoom: zoom);
    _flyTo(_centerClearOfPreview(target, point) ?? point, zoom);
  }

  void _closePreview() {
    if (_previewId != null) {
      _preview(null);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.focus?.addListener(_onFocusRequest);
    _loadZips();
  }

  @override
  void didUpdateWidget(MapScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focus != widget.focus) {
      oldWidget.focus?.removeListener(_onFocusRequest);
      widget.focus?.addListener(_onFocusRequest);
    }
  }

  void _loadZips() {
    _geocoder.ensureLoaded().then(
      (_) {
        if (mounted) setState(() => _loadError = null);
      },
      onError: (Object error) {
        debugPrint('ZIP table: $error');
        if (mounted) setState(() => _loadError = error);
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final profile = AppScope.of(context).repository.profile;
    if (!identical(profile, _profile)) {
      _profile?.removeListener(_onProfileChanged);
      _profile = profile..addListener(_onProfileChanged);
    }
  }

  @override
  void dispose() {
    _profile?.removeListener(_onProfileChanged);
    widget.focus?.removeListener(_onFocusRequest);
    _tileErrorTimer?.cancel();
    _flight.dispose();
    _controller.dispose();
    super.dispose();
  }

  static String _areaKey(SearchProfile profile) =>
      '${profile.zipCode}|${profile.radiusMiles}';

  /// Follows the user to a new search area or radius.
  void _onProfileChanged() {
    final profile = _profile?.value;
    if (profile == null || _areaKey(profile) == _centeredOn) {
      return;
    }
    _recenter();
  }

  void _recenter() {
    final profile = _profile?.value;
    final point = _geocoder.lookup(profile?.zipCode);
    if (!_mapReady || profile == null || point == null) {
      return;
    }
    _centeredOn = _areaKey(profile);
    _flyTo(point, _zoomFor(profile.radiusMiles));
  }

  /// How far from the search ZIP a lead's ZIP can be and still get a pin
  /// (see [placeLeadPins]); null pins everything. Generous, since boards
  /// match by their own idea of distance and community leads by ZIP prefix.
  static double? _areaMiles(SearchProfile? profile) =>
      profile == null ? null : math.max(profile.radiusMiles * 3.0, 100);

  /// Roughly fits the search radius on a phone screen.
  static double _zoomFor(int radiusMiles) =>
      (12 - math.log(radiusMiles / 5) / math.ln2).clamp(6, 13).toDouble();

  /// Zooms in on a cluster, far enough that its ZIPs come apart.
  void _zoomInto(LeadCluster cluster) {
    final centers = cluster.zipCenters;
    var center = cluster.point;
    var zoom = 12.0;
    if (centers.length > 1) {
      final fitted = CameraFit.coordinates(
        coordinates: centers,
        padding: const EdgeInsets.all(72),
        maxZoom: MapScreen.listZoom,
      ).fit(_controller.camera);
      center = fitted.center;
      zoom = fitted.zoom;
    }
    final current = _controller.camera.zoom;
    _flyTo(center, math.max(zoom, math.max(current + 1, MapScreen.pinZoom)));
  }

  /// A badge's tap: zooms in while that pulls its leads apart, then lists
  /// them.
  void _openCluster(LeadCluster cluster) {
    if (cluster.sameSpot || _controller.camera.zoom >= MapScreen.listZoom) {
      _closePreview();
      showLeadCluster(context, [for (final pin in cluster.pins) pin.lead]);
    } else {
      _zoomInto(cluster);
    }
  }

  /// Glides the camera to [center] and [zoom] (jumps with reduced motion).
  void _flyTo(LatLng center, double zoom) {
    _flight.stop();
    if (_flightStep case final step?) {
      _flight.removeListener(step);
    }
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      _controller.move(center, zoom);
      return;
    }
    final from = _controller.camera;
    final lat = Tween(begin: from.center.latitude, end: center.latitude);
    final lng = Tween(begin: from.center.longitude, end: center.longitude);
    final zooms = Tween(begin: from.zoom, end: zoom);
    void step() {
      final t = Curves.easeInOutCubic.transform(_flight.value);
      _controller.move(
        LatLng(lat.transform(t), lng.transform(t)),
        zooms.transform(t),
      );
    }

    _flightStep = step;
    _flight
      ..addListener(step)
      ..forward(from: 0);
  }

  void _onCameraChanged(MapCamera camera, bool hasGesture) {
    if (hasGesture && _flight.isAnimating) {
      // The user took over; don't fight them.
      _flight.stop();
    }
    // Markers sit on their points at any zoom, so only reclustering needs
    // a rebuild: done the frame the camera crosses a cluster level
    // (pinZoom is one), so it's instant.
    final last = _layoutZoom;
    if (last == null || clusterLevel(camera.zoom) != clusterLevel(last)) {
      setState(() => _layoutZoom = camera.zoom);
    }
  }

  /// Shows a notice while tiles fail, and hides it once failures stop.
  /// Pins and leads keep working without tiles.
  void _onTileError(TileImage tile, Object error, StackTrace? stack) {
    _tileErrorTimer?.cancel();
    _tileErrorTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _tilesFailing = false);
    });
    if (!_tilesFailing && mounted) {
      setState(() => _tilesFailing = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) {
      return StatusPane(
        icon: Icons.wrong_location_outlined,
        title: "The map couldn't load",
        message:
            "ZIP locations didn't load, so leads can't be placed. Your "
            'leads are still on the Leads tab.',
        action: FilledButton.tonalIcon(
          onPressed: () {
            setState(() => _loadError = null);
            _loadZips();
          },
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
      );
    }
    if (!_geocoder.isLoaded) {
      return const _MapSkeleton();
    }

    final repository = AppScope.of(context).repository;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ListenableBuilder(
      listenable: Listenable.merge([repository.leads, repository.hideSpam]),
      builder: (context, _) {
        final leads = _visible(repository);
        final profile = repository.profile.value;
        final home = _geocoder.lookup(profile?.zipCode);
        final options = _options ??= _initialOptions(profile, home, leads);
        final zoom = _layoutZoom ?? options.initialZoom;
        final layout = _layoutPins(leads, home, _areaMiles(profile));
        final pins = layout.pins;
        final regional = zoom < MapScreen.pinZoom;
        final clusters = _layoutClusters(pins, zoom);
        final current = leads.where((l) => l.id == _previewId).firstOrNull;
        final mapped = pins.length;
        bool holdsCurrent(LeadCluster cluster) =>
            current != null && cluster.pins.any((p) => p.lead.id == current.id);

        Marker marker(LeadCluster cluster) {
          if (regional) {
            return Marker(
              key: ValueKey('region-${cluster.key}'),
              point: cluster.point,
              width: 60,
              height: 60,
              child: _RegionMarker(
                count: cluster.pins.length,
                onTap: () => _zoomInto(cluster),
              ),
            );
          }
          if (cluster.pins case [final pin]) {
            return Marker(
              key: ValueKey('lead-${pin.lead.id}'),
              point: pin.zipCenter,
              width: _pinWidth,
              height: _pinHeight,
              // The pin's tip, not its middle, marks the spot.
              alignment: Alignment.topCenter,
              child: _LeadPinMarker(
                lead: pin.lead,
                selected: pin.lead.id == current?.id,
                onTap: () => _preview(pin.lead.id, focus: pin.zipCenter),
              ),
            );
          }
          return Marker(
            key: ValueKey('cluster-${cluster.key}'),
            point: cluster.point,
            width: _badgeSize,
            height: _badgeSize,
            child: _ClusterBadge(
              count: cluster.pins.length,
              sameSpot: cluster.sameSpot,
              selected: holdsCurrent(cluster),
              onTap: () => _openCluster(cluster),
            ),
          );
        }

        return Stack(
          children: [
            FlutterMap(
              mapController: _controller,
              options: options,
              children: [
                // One filter over the whole layer is far cheaper than one
                // per tile.
                ColorFiltered(
                  colorFilter: dark ? _darkTiles : _identity,
                  child: TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: MapScreen.userAgentPackageName,
                    maxNativeZoom: 19,
                    tileProvider: widget.tileProvider,
                    errorTileCallback: _onTileError,
                  ),
                ),
                if (home != null && profile != null)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _ring(home, profile.radiusMiles * 1609.34),
                        color: scheme.primary.withValues(
                          alpha: dark ? 0.8 : 0.65,
                        ),
                        strokeWidth: 2,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    for (final cluster in clusters)
                      if (!holdsCurrent(cluster)) marker(cluster),
                    // The selected lead's marker is drawn last, so it sits
                    // on top.
                    for (final cluster in clusters)
                      if (holdsCurrent(cluster)) marker(cluster),
                  ],
                ),
                const RichAttributionWidget(
                  alignment: AttributionAlignment.bottomLeft,
                  attributions: [
                    TextSourceAttribution('OpenStreetMap contributors'),
                    TextSourceAttribution('ZIP points: US Census Bureau'),
                  ],
                ),
              ],
            ),
            Positioned(
              top: Spacing.sm,
              left: Spacing.sm,
              right: 72,
              child: _Legend(
                mapped: mapped,
                unmapped: layout.unmapped,
                outside: layout.outside,
                empty: leads.isEmpty,
                regional: regional && clusters.isNotEmpty,
              ),
            ),
            if (home != null)
              Positioned(
                top: Spacing.sm,
                right: Spacing.sm,
                child: _FloatingSurface(
                  radius: AppTheme.radiusMedium,
                  child: IconButton(
                    tooltip: 'Back to my search area',
                    color: scheme.primary,
                    onPressed: () {
                      _centeredOn = null;
                      _recenter();
                    },
                    icon: const Icon(Icons.my_location),
                  ),
                ),
              ),
            // Above the attribution button, which must stay reachable.
            Positioned(
              left: Spacing.sm,
              right: Spacing.sm,
              bottom: 52,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: AppTheme.motionMedium,
                    reverseDuration: AppTheme.motionFast,
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0, 0.5),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: current == null
                        ? const SizedBox(width: double.infinity)
                        : _LeadPreview(
                            key: ValueKey(current.id),
                            lead: current,
                            onOpen: (lead) => showLeadDetails(context, lead),
                            onClose: _closePreview,
                          ),
                  ),
                  if (_tilesFailing) ...[
                    const SizedBox(height: Spacing.xs),
                    _FloatingSurface(
                      color: scheme.inverseSurface,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Spacing.md,
                          vertical: Spacing.sm,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.cloud_off,
                              color: scheme.onInverseSurface,
                              size: 20,
                            ),
                            const SizedBox(width: Spacing.sm),
                            Expanded(
                              child: Text(
                                "Map images can't load right now. Your pins "
                                'still work; tap one to open the lead.',
                                style: TextStyle(
                                  color: scheme.onInverseSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// A pin marker's box: the touch target around the visible pin.
  static const _pinWidth = 44.0;
  static const _pinHeight = 48.0;

  /// A count badge's box, also its touch target.
  static const _badgeSize = 48.0;

  /// How close (in screen pixels) two leads' spots can be before they merge
  /// into one marker: about a pin's width apart at street level, so pins
  /// never cover each other, and wider zoomed out, where the regional
  /// circles are bigger.
  static double _clusterRadius(double zoom) =>
      zoom < MapScreen.pinZoom ? 72 : 48;

  /// [LeadRepository.visible], the same list while the leads and the spam
  /// filter are unchanged, so [_layoutPins] can tell nothing moved.
  List<Lead> _visible(LeadRepository repository) {
    final all = repository.leads.value;
    final hideSpam = repository.hideSpam.value;
    final cached = _visibleLeads;
    if (cached != null &&
        identical(cached.all, all) &&
        cached.hideSpam == hideSpam) {
      return cached.visible;
    }
    final visible = repository.visible(all);
    _visibleLeads = (all: all, hideSpam: hideSpam, visible: visible);
    return visible;
  }

  /// [placeLeadPins] for [leads], or the last result if nothing it depends
  /// on changed.
  _PinLayout _layoutPins(List<Lead> leads, LatLng? home, double? areaMiles) {
    final cached = _pinLayout;
    if (cached != null &&
        identical(cached.leads, leads) &&
        cached.home == home &&
        cached.areaMiles == areaMiles) {
      return cached;
    }
    final placed = placeLeadPins(
      leads,
      _geocoder,
      area: home,
      areaMiles: areaMiles,
    );
    return _pinLayout = (
      leads: leads,
      home: home,
      areaMiles: areaMiles,
      pins: placed.pins,
      unmapped: placed.unmapped,
      outside: placed.outside,
    );
  }

  /// [clusterLeadPins] for [pins] at [zoom], reused within a cluster level.
  List<LeadCluster> _layoutClusters(List<LeadPin> pins, double zoom) {
    final cached = _clusterLayout;
    if (cached != null &&
        identical(cached.pins, pins) &&
        cached.zoom == clusterLevel(zoom)) {
      return cached.clusters;
    }
    final clusters = clusterLeadPins(
      pins,
      zoom: zoom,
      radiusPx: _clusterRadius(zoom),
    );
    _clusterLayout = (clusters: clusters, pins: pins, zoom: clusterLevel(zoom));
    return clusters;
  }

  /// Camera used only on the map's first build; afterwards the user (and
  /// [_recenter]) own it.
  MapOptions _initialOptions(
    SearchProfile? profile,
    LatLng? home,
    List<Lead> leads,
  ) {
    final points = <LatLng>{
      for (final lead in leads) ?_geocoder.lookup(lead.zipCode),
    }.toList();
    CameraFit? fit;
    if (home == null && points.length > 1) {
      fit = CameraFit.coordinates(
        coordinates: points,
        padding: const EdgeInsets.all(64),
        maxZoom: 12,
      );
    }
    return MapOptions(
      initialCenter: home ?? points.firstOrNull ?? ZipGeocoder.usCenter,
      initialZoom: home != null
          ? _zoomFor(profile!.radiusMiles)
          : points.isEmpty
          ? 3.5
          : 11,
      initialCameraFit: fit,
      minZoom: 3,
      maxZoom: 18,
      interactionOptions: const InteractionOptions(
        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
      ),
      onPositionChanged: _onCameraChanged,
      onTap: (_, _) => _closePreview(),
      onMapReady: () {
        _mapReady = true;
        if (profile != null) {
          _centeredOn = _areaKey(profile);
        }
        // A camera fit picks its own zoom; cluster for it.
        if (mounted) setState(() => _layoutZoom = _controller.camera.zoom);
        _onFocusRequest();
      },
    );
  }

  /// The search area's edge as a closed ring. Drawn as a polyline rather
  /// than a CircleMarker: flutter_map paints a circle's fill, even a
  /// transparent one, as one huge round-capped point, which Impeller
  /// renders as a square box over the area.
  static List<LatLng> _ring(LatLng center, double meters) {
    const distance = Distance();
    return [
      for (var bearing = 0; bearing <= 360; bearing += 2)
        distance.offset(center, meters, bearing),
    ];
  }

  static const _identity = ColorFilter.matrix(<double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
  ]);

  /// OSM's light tiles inverted and hue-rotated (so water stays blue and
  /// parks green), at 88% contrast with black lifted to the app's dark
  /// canvas: the map sits flush with the UI instead of as a black hole,
  /// and land, water, roads and labels stay apart.
  static const _darkTiles = ColorFilter.matrix(<double>[
    0.50512, -1.2584, -0.12672, 0, 238.4, //
    -0.37488, -0.3784, -0.12672, 0, 242.4,
    -0.37488, -1.2584, 0.75328, 0, 244.4,
    0, 0, 0, 1, 0,
  ]);
}

typedef _PinLayout = ({
  List<Lead> leads,
  LatLng? home,
  double? areaMiles,
  List<LeadPin> pins,
  int unmapped,
  int outside,
});

class _LeadPinMarker extends StatelessWidget {
  const _LeadPinMarker({
    required this.lead,
    required this.selected,
    required this.onTap,
  });

  final Lead lead;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final community = lead.source == LeadSource.internal;
    final color = community ? scheme.tertiary : scheme.primary;
    final foreground = community ? scheme.onTertiary : scheme.onPrimary;
    final trust = lead.trust;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
      button: true,
      selected: selected,
      label: [
        lead.displayTitle,
        lead.budgetLabel,
        if (trust != null) trust.label,
      ].join(', '),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // The 44px marker box is the touch target; the visible pin is
        // smaller so neighbors stay readable.
        child: Align(
          alignment: Alignment.bottomCenter,
          child: AnimatedScale(
            scale: selected ? 1.25 : 1,
            alignment: Alignment.bottomCenter,
            duration: still ? Duration.zero : AppTheme.motionMedium,
            curve: Curves.easeOutBack,
            // Pins move every frame while the map pans and zooms; caching
            // each one's shadowed paint keeps that cheap.
            child: RepaintBoundary(
              child: Opacity(
                // Possible spam stays tappable but recedes.
                opacity: trust == LeadTrust.spam ? 0.5 : 1,
                child: CustomPaint(
                  painter: _PinPainter(
                    color: color,
                    // Selection gets the ink color: dark on the light map,
                    // light on the dark one, so it reads in both.
                    ring: lead.isFavorite
                        ? Colors.amber.shade600
                        : selected
                        ? scheme.onSurface
                        : Colors.white,
                    ringWidth: lead.isFavorite || selected ? 3 : 2,
                  ),
                  child: SizedBox(
                    width: 30,
                    height: 38,
                    child: Align(
                      alignment: const Alignment(0, -0.62),
                      child: Icon(
                        lead.isFavorite
                            ? Icons.star
                            : community
                            ? Icons.people_alt
                            : Icons.work,
                        size: 14,
                        color: foreground,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Several nearby leads on a zoomed-out map: a count in a teal disc. A tap
/// zooms in until they show as single pins.
class _RegionMarker extends StatelessWidget {
  const _RegionMarker({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 36px for one lead, 48px for ten, 56px from about fifty.
    final size = (36 + 12 * math.log(count) / math.ln10).clamp(36.0, 56.0);
    return Semantics(
      button: true,
      label: '$count lead${count == 1 ? '' : 's'} in this area. Zoom in',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2.5),
              boxShadow: AppShadows.of(context).floating,
            ),
            child: Text(
              '$count',
              maxLines: 1,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                color: scheme.onPrimary,
                fontSize: count > 99 ? 13 : 15,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Several leads that would cover each other at this zoom: a compact count
/// badge. A tap zooms in to separate them, or lists them when they share
/// one spot ([sameSpot]).
class _ClusterBadge extends StatelessWidget {
  const _ClusterBadge({
    required this.count,
    required this.sameSpot,
    required this.selected,
    required this.onTap,
  });

  final int count;
  final bool sameSpot;

  /// Holds the lead in the preview card.
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 32px for two leads, up to 42px from about fifty.
    final size = (28 + 8 * math.log(count) / math.ln10).clamp(32.0, 42.0);
    return Semantics(
      button: true,
      selected: selected,
      label: sameSpot
          ? '$count leads here. Show list'
          : '$count leads nearby. Zoom in',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: RepaintBoundary(
            child: Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? scheme.onSurface : Colors.white,
                  width: selected ? 3 : 2,
                ),
                boxShadow: AppShadows.of(context).floating,
              ),
              child: Text(
                count > 99 ? '99+' : '$count',
                maxLines: 1,
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontSize: count > 99 ? 11 : 13,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lists [leads] that share one spot on the map in a sheet, newest first,
/// each with Reply; a row's tap opens the lead's details.
Future<void> showLeadCluster(BuildContext context, List<Lead> leads) {
  final sorted = List.of(leads)
    ..sort((a, b) => b.sortTime.compareTo(a.sortTime));
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    sheetAnimationStyle: const AnimationStyle(
      duration: AppTheme.motionSlow,
      reverseDuration: AppTheme.motionMedium,
    ),
    builder: (_) => _ClusterSheet(leads: sorted),
  );
}

class _ClusterSheet extends StatelessWidget {
  const _ClusterSheet({required this.leads});

  final List<Lead> leads;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // The most common place name, e.g. "Bensalem · 19020".
    final places = <String, int>{};
    for (final lead in leads) {
      final place = [
        if (lead.location.isNotEmpty) lead.location,
        if (lead.zipCode.isNotEmpty) lead.zipCode,
      ].join(' · ');
      if (place.isNotEmpty) places[place] = (places[place] ?? 0) + 1;
    }
    final place = places.entries
        .fold<MapEntry<String, int>?>(
          null,
          (best, e) => best == null || e.value > best.value ? e : best,
        )
        ?.key;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: leads.length <= 3 ? 0.5 : 0.65,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView.separated(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(
          Spacing.md,
          0,
          Spacing.md,
          Spacing.lg,
        ),
        itemCount: leads.length + 1,
        separatorBuilder: (_, i) => i == 0
            ? const SizedBox(height: Spacing.sm)
            : const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i == 0) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${leads.length} leads here',
                  style: textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (place != null) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(
                        Icons.place_outlined,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          place,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            );
          }
          return _ClusterRow(lead: leads[i - 1]);
        },
      ),
    );
  }
}

/// One lead in [_ClusterSheet]: title, budget and age, with Reply.
class _ClusterRow extends StatelessWidget {
  const _ClusterRow({required this.lead});

  final Lead lead;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final age = timeAgo(
      lead.sortTime.millisecondsSinceEpoch == 0 ? null : lead.sortTime,
    );
    final trust = lead.trust;
    return InkWell(
      borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      onTap: () => showLeadDetails(context, lead),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    lead.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: lead.budgetLabel,
                          style: TextStyle(
                            color: scheme.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        TextSpan(
                          text: [
                            '',
                            if (lead.category.isNotEmpty) lead.category,
                            if (trust == LeadTrust.spam) trust!.label,
                            if (age.isNotEmpty) age,
                          ].join(' · '),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Spacing.sm),
            if (ReplyButton.canReply(lead))
              ReplyButton(lead: lead, style: _PreviewActions._size)
            else
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// A teardrop map pin: a round head over a point that marks the spot.
class _PinPainter extends CustomPainter {
  const _PinPainter({
    required this.color,
    required this.ring,
    required this.ringWidth,
  });

  final Color color;
  final Color ring;
  final double ringWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.width / 2 - 1;
    final center = Offset(size.width / 2, radius + 1);
    final tip = Offset(size.width / 2, size.height - 1);
    // Tangent points where the head meets the tail.
    final spread = radius * 0.62;
    final shoulder = center.dy + radius * 0.78;
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(center.dx - spread, shoulder)
      ..arcTo(
        Rect.fromCircle(center: center, radius: radius),
        2.24,
        2 * 3.14159265 - 1.34,
        false,
      )
      ..close();
    canvas.drawShadow(path, const Color(0xFF000000), 3, false);
    canvas.drawPath(path, Paint()..color = ring);
    final inner = radius - ringWidth;
    canvas.drawCircle(center, inner, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_PinPainter old) =>
      old.color != color || old.ring != ring || old.ringWidth != ringWidth;
}

/// Raised, rounded surface for controls floating over the map.
class _FloatingSurface extends StatelessWidget {
  const _FloatingSurface({
    required this.child,
    this.color,
    this.radius = AppTheme.radiusLarge,
  });

  final Widget child;
  final Color? color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? theme.cardTheme.color ?? theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: AppShadows.of(context).floating,
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}

/// The floating card for the tapped pin's lead: badges, title, budget and
/// place, with Reply and View details.
class _LeadPreview extends StatelessWidget {
  const _LeadPreview({
    super.key,
    required this.lead,
    required this.onOpen,
    required this.onClose,
  });

  final Lead lead;
  final ValueChanged<Lead> onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: _FloatingSurface(
          child: InkWell(
            onTap: () => onOpen(lead),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.md,
                Spacing.xs,
                Spacing.xxs,
                Spacing.md,
              ),
              child: _PreviewBody(
                lead: lead,
                onOpen: () => onOpen(lead),
                onClose: onClose,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewBody extends StatelessWidget {
  const _PreviewBody({
    required this.lead,
    required this.onOpen,
    required this.onClose,
  });

  final Lead lead;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final trust = lead.trust;
    final place = [
      if (lead.location.isNotEmpty) lead.location,
      if (lead.zipCode.isNotEmpty) '${lead.zipCode} area',
    ].join(' · ');
    final age = timeAgo(
      lead.sortTime.millisecondsSinceEpoch == 0 ? null : lead.sortTime,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: Spacing.xs),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (trust != null) TrustBadge(trust: trust, dense: true),
                    SourceBadge(lead: lead),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: 'Close preview',
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 20),
            ),
          ],
        ),
        const SizedBox(height: Spacing.xxs),
        Padding(
          padding: const EdgeInsets.only(right: Spacing.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  lead.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  lead.budgetLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleMedium?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.xxs),
        Padding(
          padding: const EdgeInsets.only(right: Spacing.sm),
          child: Row(
            children: [
              Icon(
                Icons.place_outlined,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 3),
              Expanded(
                child: Text(
                  [
                    place.isEmpty ? 'Location not listed' : place,
                    if (age.isNotEmpty) age,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Padding(
          padding: const EdgeInsets.only(right: Spacing.sm),
          child: _PreviewActions(lead: lead, onOpen: onOpen),
        ),
      ],
    );
  }
}

/// The preview's two actions: Reply (by phone, text, email or on the
/// listing) and View details. A lead with no way to reply shows only
/// View details.
class _PreviewActions extends StatelessWidget {
  const _PreviewActions({required this.lead, required this.onOpen});

  final Lead lead;
  final VoidCallback onOpen;

  static const _size = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(0, 44)),
    padding: WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: Spacing.sm),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (ReplyButton.canReply(lead)) ...[
          Expanded(
            child: ReplyButton(lead: lead, style: _size),
          ),
          const SizedBox(width: Spacing.xs),
        ],
        Expanded(
          child: FilledButton.tonal(
            onPressed: onOpen,
            style: _size,
            child: const Text(
              'View details',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }
}

/// Shimmering stand-in while the ZIP table loads.
class _MapSkeleton extends StatelessWidget {
  const _MapSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Loading map',
      child: Shimmer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ShimmerBones(child: SkeletonBox(radius: 0, height: null)),
            Center(
              child: Icon(
                Icons.map_outlined,
                size: 48,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lead count and the pin colors, in a compact floating card.
class _Legend extends StatelessWidget {
  const _Legend({
    required this.mapped,
    required this.unmapped,
    required this.outside,
    required this.empty,
    required this.regional,
  });

  final int mapped;
  final int unmapped;
  final int outside;
  final bool empty;

  /// Leads are grouped into regional markers rather than pinned.
  final bool regional;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    Widget dot(Color color, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
    return Align(
      alignment: Alignment.topLeft,
      child: _FloatingSurface(
        radius: AppTheme.radiusMedium,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.xs,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                empty
                    ? 'No leads yet. Search on the Leads tab.'
                    : '$mapped lead${mapped == 1 ? '' : 's'} on the map'
                          '${unmapped == 0 ? '' : ' · $unmapped without a ZIP'}'
                          '${outside == 0 ? '' : ' · $outside outside your area'}',
                style: textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (!empty && regional) ...[
                const SizedBox(height: Spacing.xxs),
                Text(
                  'Zoom in or tap a circle to see each lead',
                  style: textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ] else if (!empty) ...[
                const SizedBox(height: Spacing.xxs),
                Wrap(
                  spacing: Spacing.sm,
                  runSpacing: Spacing.xxs,
                  children: [
                    dot(scheme.primary, 'Listing'),
                    dot(scheme.tertiary, 'Direct customer'),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
