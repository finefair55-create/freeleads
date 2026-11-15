import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_leads/sources/listing_fetch_service.dart';
import 'package:free_leads/sources/request_policy.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class MemoryCooldowns implements HostCooldownStore {
  final saved = <String, DateTime?>{};

  @override
  DateTime? cooldownUntil(String host) => saved[host];

  @override
  Future<void> saveCooldown(String host, DateTime? until) async =>
      saved[host] = until;
}

void main() {
  final page = Uri.parse('https://www.craigslist.org/search?query=plumber');
  late DateTime now;
  late List<http.Request> requests;

  setUp(() {
    now = DateTime(2026, 10, 16, 9);
    requests = [];
  });

  ListingFetchService fetcher(
    http.Response Function(http.Request request) respond, {
    RequestPolicy policy = RequestPolicy.unthrottled,
    HostCooldownStore? cooldowns,
  }) {
    return ListingFetchService(
      client: MockClient((request) async {
        requests.add(request);
        return respond(request);
      }),
      siteName: 'Craigslist',
      policy: policy,
      cooldowns: cooldowns,
      maxAttempts: 1,
      now: () => now,
    );
  }

  test('a 403 pauses the host instead of retrying into a ban', () async {
    final store = MemoryCooldowns();
    final service = fetcher((_) => http.Response('', 403), cooldowns: store);

    await expectLater(
      service.fetchRaw(page),
      throwsA(
        isA<ListingFetchException>()
            .having((e) => e.failure, 'failure', FetchFailure.blocked)
            .having((e) => e.isPaused, 'isPaused', isTrue)
            .having((e) => e.message, 'message', contains('Craigslist')),
      ),
    );
    expect(requests, hasLength(1));
    final until = now.add(const RequestPolicy().cooldown);
    expect(service.statusFor(page.host).pausedUntil, until);
    expect(store.saved[page.host], until, reason: 'survives a restart');

    // Paused: fails fast without touching the network.
    await expectLater(
      service.fetchRaw(page),
      throwsA(
        isA<ListingFetchException>().having(
          (e) => e.failure,
          'failure',
          FetchFailure.coolingDown,
        ),
      ),
    );
    expect(requests, hasLength(1));

    // A fresh service (app restart) honors the stored pause.
    final restarted = fetcher(
      (_) => http.Response('ok', 200),
      cooldowns: store,
    );
    await expectLater(
      restarted.fetchRaw(page),
      throwsA(isA<ListingFetchException>()),
    );
    expect(requests, hasLength(1));

    now = until.add(const Duration(seconds: 1));
    expect(await restarted.fetchRaw(page), 'ok');
  });

  test('Retry-After wins when longer than the default pause', () async {
    final service = fetcher(
      (_) => http.Response('', 429, headers: {'retry-after': '3600'}),
    );
    await expectLater(
      service.fetchRaw(page),
      throwsA(isA<ListingFetchException>()),
    );
    expect(
      service.statusFor(page.host).pausedUntil,
      now.add(const Duration(hours: 1)),
    );
  });

  test('repeat blocks back off exponentially up to the cap', () {
    const policy = RequestPolicy();
    expect(policy.cooldownFor(1), const Duration(minutes: 15));
    expect(policy.cooldownFor(2), const Duration(minutes: 30));
    expect(policy.cooldownFor(3), const Duration(hours: 1));
    expect(policy.cooldownFor(20), policy.maxCooldown);
  });

  test('the hourly budget stops requests before the site has to', () async {
    final service = fetcher(
      (_) => http.Response('ok', 200),
      policy: const RequestPolicy(
        minInterval: Duration.zero,
        jitter: Duration.zero,
        maxRequestsPerHour: 2,
      ),
    );
    await service.fetchRaw(page);
    await service.fetchRaw(page);
    await expectLater(
      service.fetchRaw(page),
      throwsA(
        isA<ListingFetchException>()
            .having((e) => e.failure, 'failure', FetchFailure.budget)
            .having(
              (e) => e.retryAt,
              'retryAt',
              now.add(const Duration(hours: 1)),
            ),
      ),
    );
    expect(requests, hasLength(2));
    expect(service.statusFor(page.host).requestsLastHour, 2);

    now = now.add(const Duration(minutes: 61));
    expect(await service.fetchRaw(page), 'ok');
  });

  test('requests are spaced by the interval plus jitter', () async {
    const policy = RequestPolicy(
      minInterval: Duration(milliseconds: 40),
      jitter: Duration(milliseconds: 20),
    );
    final random = Random(1);
    for (var i = 0; i < 50; i++) {
      final gap = policy.nextGap(random).inMilliseconds;
      expect(gap, inInclusiveRange(40, 60));
    }

    final times = <DateTime>[];
    final service = ListingFetchService(
      client: MockClient((_) async {
        times.add(DateTime.now());
        return http.Response('ok', 200);
      }),
      policy: policy,
      maxAttempts: 1,
    );
    await Future.wait([service.fetchRaw(page), service.fetchRaw(page)]);
    expect(
      times[1].difference(times[0]).inMilliseconds,
      greaterThanOrEqualTo(38),
    );
  });

  test('one browser identity is used for the whole session', () async {
    final service = fetcher((_) => http.Response('ok', 200));
    await service.fetchRaw(page);
    await service.fetchRaw(page);
    final agents = requests.map((r) => r.headers['User-Agent']).toSet();
    expect(agents, hasLength(1));
    expect(agents.single, startsWith('Mozilla/5.0'));
    expect(requests.first.headers['Accept-Language'], isNotEmpty);

    for (final platform in TargetPlatform.values) {
      expect(BrowserIdentity.poolFor(platform), isNotEmpty);
    }
    expect(
      BrowserIdentity.poolFor(TargetPlatform.iOS).first.userAgent,
      contains('iPhone'),
    );
    expect(
      BrowserIdentity.poolFor(TargetPlatform.android).first.userAgent,
      contains('Android'),
    );
  });

  test('server errors are retried, a closed service refuses work', () async {
    var calls = 0;
    final service = ListingFetchService(
      client: MockClient((_) async {
        calls++;
        return calls == 1 ? http.Response('', 503) : http.Response('ok', 200);
      }),
      policy: RequestPolicy.unthrottled,
      maxAttempts: 2,
    );
    expect(await service.fetchRaw(page), 'ok');
    expect(calls, 2);

    service.close();
    expect(() => service.fetchRaw(page), throwsStateError);
  });
}
