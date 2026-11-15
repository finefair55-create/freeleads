import 'dart:async';
import 'dart:io' show HttpDate, HttpException;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'request_policy.dart';

enum FetchFailure {
  /// Couldn't reach the site at all (offline, DNS, timeout).
  network,

  /// The site answered 403/429; the host is now paused.
  blocked,

  /// The host is still paused after an earlier block.
  coolingDown,

  /// FreeLeads' own hourly request budget for the host is used up.
  budget,

  notFound,

  /// Any other HTTP error.
  http,

  /// Scraping can't run here (web builds).
  unsupported,
}

class ListingFetchException implements Exception {
  ListingFetchException(
    this.message, {
    this.uri,
    this.statusCode,
    this.failure = FetchFailure.http,
    this.retryAt,
  });

  final String message;
  final Uri? uri;
  final int? statusCode;
  final FetchFailure failure;

  /// When the host may be tried again, for paused hosts.
  final DateTime? retryAt;

  /// True when the site couldn't be reached at all (offline, DNS, timeout).
  bool get isNetwork => failure == FetchFailure.network;

  /// True when searching the host is on hold to avoid a ban.
  bool get isPaused =>
      failure == FetchFailure.blocked ||
      failure == FetchFailure.coolingDown ||
      failure == FetchFailure.budget;

  @override
  String toString() => 'ListingFetchException: $message';
}

/// Request activity for one host, for the Profile tab.
@immutable
class HostStatus {
  const HostStatus({
    required this.requestsLastHour,
    required this.hourlyLimit,
    this.pausedUntil,
  });

  final int requestsLastHour;
  final int hourlyLimit;
  final DateTime? pausedUntil;

  bool get isPaused => pausedUntil != null;
}

/// Fetches public listing pages from the user's own device, within a
/// [RequestPolicy]: requests to a host are spaced with random jitter and
/// capped per hour, and a 403/429 pauses the host (honoring `Retry-After`)
/// instead of retrying into a ban. Network errors and 5xx responses are
/// retried with backoff.
class ListingFetchService {
  ListingFetchService({
    http.Client? client,
    this.siteName = 'The listing site',
    this.timeout = const Duration(seconds: 15),
    this.maxAttempts = 3,
    this.policy = const RequestPolicy(),
    this.cooldowns,
    BrowserIdentity? identity,
    Random? random,
    DateTime Function()? now,
  }) : _client = client ?? http.Client(),
       _random = random ?? Random(),
       _now = now ?? DateTime.now,
       identity = identity ?? BrowserIdentity.pick(random: random);

  final http.Client _client;

  /// How messages refer to the site, e.g. "Craigslist".
  final String siteName;
  final Duration timeout;
  final int maxAttempts;
  final RequestPolicy policy;

  /// Persists pauses across restarts; optional.
  final HostCooldownStore? cooldowns;

  /// Browser headers used for every request this session.
  final BrowserIdentity identity;

  final Random _random;
  final DateTime Function() _now;

  final _nextSlotByHost = <String, DateTime>{};
  final _requestLog = <String, List<DateTime>>{};
  final _pausedUntil = <String, DateTime?>{};
  final _strikes = <String, int>{};
  late final Map<String, String> _headers = identity.headers(
    acceptLanguage: _acceptLanguage(),
  );
  bool _closed = false;

  Future<String> fetchRaw(Uri url) async {
    if (kIsWeb) {
      // Browsers enforce CORS, and boards do not send CORS headers.
      throw ListingFetchException(
        'Scraping runs on the mobile and desktop apps only, not in a browser.',
        uri: url,
        failure: FetchFailure.unsupported,
      );
    }
    if (_closed) {
      throw StateError('ListingFetchService was closed.');
    }
    final host = url.host;

    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      _ensureAllowed(host, url);
      await _throttle(host);
      // Another request may have been blocked while this one waited.
      _ensureAllowed(host, url);
      _record(host);
      try {
        final response = await _client
            .get(url, headers: _headers)
            .timeout(timeout);
        final status = response.statusCode;
        if (status == 200) {
          _clearStrikes(host);
          return response.body;
        }
        if (status == 403 || status == 429) {
          final until = _pause(host, response);
          throw ListingFetchException(
            '$siteName is limiting requests from your network, so FreeLeads '
            'paused searching it until ${_clock(until)} to keep your '
            'connection in good standing.',
            uri: url,
            statusCode: status,
            failure: FetchFailure.blocked,
            retryAt: until,
          );
        }
        if (status == 404) {
          throw ListingFetchException(
            'Listing page not found (HTTP 404).',
            uri: url,
            statusCode: status,
            failure: FetchFailure.notFound,
          );
        }
        lastError = ListingFetchException(
          '$siteName returned HTTP $status.',
          uri: url,
          statusCode: status,
        );
        if (status < 500) {
          throw lastError;
        }
      } on ListingFetchException {
        rethrow;
      } on TimeoutException catch (error) {
        lastError = error;
      } on http.ClientException catch (error) {
        lastError = error;
      }
      if (attempt < maxAttempts) {
        final backoffMs = 800 * pow(2, attempt - 1) + _random.nextInt(400);
        await Future<void>.delayed(Duration(milliseconds: backoffMs.toInt()));
      }
    }
    if (lastError is ListingFetchException) {
      throw lastError;
    }
    debugPrint('Could not reach $host: $lastError');
    throw ListingFetchException(
      "You're offline or the connection is too weak to search right now. "
      'Your saved leads are still available.',
      uri: url,
      failure: FetchFailure.network,
    );
  }

  /// Current activity and pause state for [host].
  HostStatus statusFor(String host) {
    final paused = _activePause(host);
    return HostStatus(
      requestsLastHour: _recent(host).length,
      hourlyLimit: policy.maxRequestsPerHour,
      pausedUntil: paused,
    );
  }

  /// Throws if [host] is paused or over its hourly budget.
  void _ensureAllowed(String host, Uri url) {
    final paused = _activePause(host);
    if (paused != null) {
      throw ListingFetchException(
        'Searching $siteName is paused until ${_clock(paused)} because it '
        'limited requests from your network.',
        uri: url,
        failure: FetchFailure.coolingDown,
        retryAt: paused,
      );
    }
    final recent = _recent(host);
    if (recent.length >= policy.maxRequestsPerHour) {
      final retryAt = recent.first.add(const Duration(hours: 1));
      throw ListingFetchException(
        'FreeLeads reached its hourly limit for $siteName so your network '
        "doesn't get blocked. It will search again after ${_clock(retryAt)}.",
        uri: url,
        failure: FetchFailure.budget,
        retryAt: retryAt,
      );
    }
  }

  DateTime? _activePause(String host) {
    final until = _pausedUntil.putIfAbsent(
      host,
      () => cooldowns?.cooldownUntil(host),
    );
    if (until == null) {
      return null;
    }
    if (!until.isAfter(_now())) {
      _pausedUntil[host] = null;
      return null;
    }
    return until;
  }

  int _strikeCount(String host) => _strikes.putIfAbsent(host, () {
    final store = cooldowns;
    return store is HostBackoffStore ? store.strikes(host) : 0;
  });

  void _clearStrikes(String host) {
    if (_strikeCount(host) == 0) {
      return;
    }
    _strikes[host] = 0;
    _saveStrikes(host, 0);
  }

  void _saveStrikes(String host, int strikes) {
    final store = cooldowns;
    if (store is HostBackoffStore) {
      unawaited(
        store
            .saveStrikes(host, strikes)
            .catchError((Object e) => debugPrint('Saving strikes: $e')),
      );
    }
  }

  DateTime _pause(String host, http.Response response) {
    final strike = _strikeCount(host) + 1;
    _strikes[host] = strike;
    _saveStrikes(host, strike);
    var pause = policy.cooldownFor(strike);
    final retryAfter = _retryAfter(response.headers['retry-after']);
    if (retryAfter != null && retryAfter > pause) {
      pause = retryAfter > policy.maxCooldown ? policy.maxCooldown : retryAfter;
    }
    final until = _now().add(pause);
    _pausedUntil[host] = until;
    debugPrint('$host answered ${response.statusCode}; paused until $until.');
    final store = cooldowns;
    if (store != null) {
      unawaited(
        store
            .saveCooldown(host, until)
            .catchError((Object e) => debugPrint('Saving cooldown: $e')),
      );
    }
    return until;
  }

  /// `Retry-After` as seconds or an HTTP date.
  Duration? _retryAfter(String? value) {
    if (value == null) {
      return null;
    }
    final seconds = int.tryParse(value.trim());
    if (seconds != null) {
      return Duration(seconds: seconds);
    }
    try {
      final at = HttpDate.parse(value);
      final wait = at.difference(_now());
      return wait.isNegative ? null : wait;
    } on FormatException {
      return null;
    } on HttpException {
      return null;
    }
  }

  List<DateTime> _recent(String host) {
    final log = _requestLog.putIfAbsent(host, () => []);
    final cutoff = _now().subtract(const Duration(hours: 1));
    log.removeWhere((time) => time.isBefore(cutoff));
    return log;
  }

  void _record(String host) => _recent(host).add(_now());

  /// Reserves the next free slot for [host] synchronously, so concurrent
  /// callers queue up instead of all firing at once.
  Future<void> _throttle(String host) async {
    final now = DateTime.now();
    final next = _nextSlotByHost[host];
    final slot = next == null || next.isBefore(now) ? now : next;
    _nextSlotByHost[host] = slot.add(policy.nextGap(_random));
    final wait = slot.difference(now);
    if (wait > Duration.zero) {
      await Future<void>.delayed(wait);
    }
  }

  String _clock(DateTime time) {
    final local = time.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final suffix = local.hour < 12 ? 'AM' : 'PM';
    final now = _now().toLocal();
    final sameDay =
        local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    return '$hour:$minute $suffix${sameDay ? '' : ' tomorrow'}';
  }

  static String _acceptLanguage() {
    try {
      final locale = PlatformDispatcher.instance.locale;
      final tag = locale.toLanguageTag();
      if (tag.isEmpty || tag == 'und') {
        return 'en-US,en;q=0.9';
      }
      return tag == locale.languageCode
          ? tag
          : '$tag,${locale.languageCode};q=0.9';
    } catch (_) {
      return 'en-US,en;q=0.9';
    }
  }

  void close() {
    _closed = true;
    _client.close();
  }
}
