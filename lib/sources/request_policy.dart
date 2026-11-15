import 'dart:math';

import 'package:flutter/foundation.dart';

/// How politely a [ListingSource] may hit its site. Requests are spaced by
/// [minInterval] plus a random share of [jitter], capped at
/// [maxRequestsPerHour], and a block (HTTP 403/429) pauses the host for
/// [cooldown], doubling on each repeat up to [maxCooldown].
///
/// Requests go out from the user's own phone and IP, so a ban would hit
/// the user, not a server. These limits keep traffic in line with one
/// person browsing.
@immutable
class RequestPolicy {
  const RequestPolicy({
    this.minInterval = const Duration(milliseconds: 1000),
    this.jitter = const Duration(milliseconds: 1500),
    this.maxRequestsPerHour = 120,
    this.cooldown = const Duration(minutes: 15),
    this.maxCooldown = const Duration(hours: 6),
  });

  /// No spacing or budget; for tests against fake clients.
  static const unthrottled = RequestPolicy(
    minInterval: Duration.zero,
    jitter: Duration.zero,
    maxRequestsPerHour: 1 << 30,
  );

  final Duration minInterval;
  final Duration jitter;
  final int maxRequestsPerHour;
  final Duration cooldown;
  final Duration maxCooldown;

  /// Gap before the next request: [minInterval] plus up to [jitter].
  Duration nextGap(Random random) {
    final extra = jitter.inMilliseconds <= 0
        ? 0
        : random.nextInt(jitter.inMilliseconds + 1);
    return minInterval + Duration(milliseconds: extra);
  }

  /// Pause after the [strike]th block in a row (1-based).
  Duration cooldownFor(int strike) {
    final factor = 1 << (strike - 1).clamp(0, 10);
    final pause = cooldown * factor;
    return pause > maxCooldown ? maxCooldown : pause;
  }
}

/// Remembers host pauses across app restarts, so relaunching the app
/// doesn't hit a site that just blocked the device.
abstract interface class HostCooldownStore {
  DateTime? cooldownUntil(String host);
  Future<void> saveCooldown(String host, DateTime? until);
}

/// A [HostCooldownStore] that also remembers how many blocks in a row a
/// host has answered with, so the exponential backoff keeps growing after
/// a restart instead of starting over at the shortest pause.
abstract interface class HostBackoffStore implements HostCooldownStore {
  int strikes(String host);
  Future<void> saveStrikes(String host, int strikes);
}

/// One consistent set of browser headers, kept for the whole app session.
///
/// Changing identity on every request looks more like a bot than a fixed
/// one, so a profile is picked once per session from the browsers that
/// actually run on this platform.
@immutable
class BrowserIdentity {
  const BrowserIdentity(this.name, this.userAgent);

  final String name;
  final String userAgent;

  /// Keep within a few releases of current stable.
  static const _chrome = ['150', '151', '152'];
  static const _safari = ['26.0', '26.1'];
  static const _firefox = ['144.0', '145.0'];

  static List<BrowserIdentity> poolFor(TargetPlatform platform) {
    switch (platform) {
      case TargetPlatform.android:
        // Chrome's reduced user agent: no device model or OS build.
        return [
          for (final v in _chrome)
            BrowserIdentity(
              'Chrome $v (Android)',
              'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/$v.0.0.0 Mobile Safari/537.36',
            ),
          for (final v in _firefox)
            BrowserIdentity(
              'Firefox $v (Android)',
              'Mozilla/5.0 (Android 15; Mobile; rv:$v) Gecko/$v Firefox/$v',
            ),
        ];
      case TargetPlatform.iOS:
        return [
          for (final v in _safari)
            BrowserIdentity(
              'Safari $v (iPhone)',
              'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) '
                  'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/$v '
                  'Mobile/15E148 Safari/604.1',
            ),
        ];
      case TargetPlatform.macOS:
        return [
          for (final v in _safari)
            BrowserIdentity(
              'Safari $v (Mac)',
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
                  'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/$v '
                  'Safari/605.1.15',
            ),
        ];
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        final os = platform == TargetPlatform.windows
            ? 'Windows NT 10.0; Win64; x64'
            : 'X11; Linux x86_64';
        return [
          for (final v in _chrome)
            BrowserIdentity(
              'Chrome $v (desktop)',
              'Mozilla/5.0 ($os) AppleWebKit/537.36 (KHTML, like Gecko) '
                  'Chrome/$v.0.0.0 Safari/537.36',
            ),
        ];
    }
  }

  static BrowserIdentity pick({TargetPlatform? platform, Random? random}) {
    final pool = poolFor(platform ?? defaultTargetPlatform);
    return pool[(random ?? Random()).nextInt(pool.length)];
  }

  Map<String, String> headers({String acceptLanguage = 'en-US,en;q=0.9'}) => {
    'User-Agent': userAgent,
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': acceptLanguage,
  };
}
