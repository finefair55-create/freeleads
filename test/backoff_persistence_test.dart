import 'package:flutter_test/flutter_test.dart';
import 'package:free_leads/sources/listing_fetch_service.dart';
import 'package:free_leads/sources/request_policy.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class MemoryBackoff implements HostBackoffStore {
  final cooldowns = <String, DateTime?>{};
  final strikeCounts = <String, int>{};

  @override
  DateTime? cooldownUntil(String host) => cooldowns[host];

  @override
  Future<void> saveCooldown(String host, DateTime? until) async =>
      cooldowns[host] = until;

  @override
  int strikes(String host) => strikeCounts[host] ?? 0;

  @override
  Future<void> saveStrikes(String host, int strikes) async =>
      strikeCounts[host] = strikes;
}

void main() {
  final page = Uri.parse('https://www.craigslist.org/search?query=plumber');
  const policy = RequestPolicy(
    minInterval: Duration.zero,
    jitter: Duration.zero,
  );

  ListingFetchService session(
    MemoryBackoff store,
    DateTime Function() now,
    int status,
  ) {
    return ListingFetchService(
      client: MockClient((_) async => http.Response('ok', status)),
      policy: policy,
      cooldowns: store,
      maxAttempts: 1,
      now: now,
    );
  }

  test('backoff keeps doubling across app restarts', () async {
    final store = MemoryBackoff();
    var now = DateTime(2026, 10, 16, 9);

    // First session: blocked once, 15 minute pause.
    final first = session(store, () => now, 429);
    await expectLater(
      first.fetchRaw(page),
      throwsA(isA<ListingFetchException>()),
    );
    expect(store.strikes(page.host), 1);
    expect(store.cooldownUntil(page.host), now.add(policy.cooldownFor(1)));
    first.close();

    // Relaunch after the pause; blocked again, so the pause doubles.
    now = now.add(const Duration(minutes: 16));
    final second = session(store, () => now, 403);
    await expectLater(
      second.fetchRaw(page),
      throwsA(
        isA<ListingFetchException>().having(
          (e) => e.retryAt,
          'retryAt',
          now.add(const Duration(minutes: 30)),
        ),
      ),
    );
    expect(store.strikes(page.host), 2);
    second.close();

    // A later success clears the remembered strikes.
    now = now.add(const Duration(minutes: 31));
    final third = session(store, () => now, 200);
    expect(await third.fetchRaw(page), 'ok');
    expect(store.strikes(page.host), 0);
    third.close();
  });

  test('a paused host is not contacted after a restart', () async {
    final store = MemoryBackoff();
    final now = DateTime(2026, 10, 16, 9);
    store.cooldowns[page.host] = now.add(const Duration(hours: 1));
    var calls = 0;
    final service = ListingFetchService(
      client: MockClient((_) async {
        calls++;
        return http.Response('ok', 200);
      }),
      policy: policy,
      cooldowns: store,
      maxAttempts: 1,
      now: () => now,
    );
    addTearDown(service.close);

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
    expect(calls, 0);
  });

  test('default policy is 1s + jitter and 120 requests per hour', () {
    const policy = RequestPolicy();
    expect(policy.minInterval, const Duration(seconds: 1));
    expect(policy.jitter, greaterThan(Duration.zero));
    expect(policy.maxRequestsPerHour, 120);
  });
}
