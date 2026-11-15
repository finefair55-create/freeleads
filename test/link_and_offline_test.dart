import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_leads/services/gemini_service.dart';
import 'package:free_leads/sources/listing_fetch_service.dart';
import 'package:free_leads/sources/request_policy.dart';
import 'package:free_leads/widgets/link_opener.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('safeWebUri', () {
    test('accepts absolute http(s) links', () {
      expect(
        safeWebUri(' https://newyork.craigslist.org/brk/lbg/d/x/123.html '),
        Uri.parse('https://newyork.craigslist.org/brk/lbg/d/x/123.html'),
      );
      expect(safeWebUri('http://example.com'), isNotNull);
    });

    test('refuses anything a scraped or posted lead could abuse', () {
      for (final bad in [
        null,
        '',
        'not a url',
        '/view/d/x/123',
        'javascript:alert(1)',
        'intent://evil#Intent;end',
        'file:///etc/passwd',
        'tel:5550100',
        'https://',
        'http://[::1',
      ]) {
        expect(safeWebUri(bad), isNull, reason: '$bad');
      }
    });
  });

  group('openExternalLink', () {
    late UrlOpener original;
    setUp(() => original = urlOpener);
    tearDown(() => urlOpener = original);

    Future<void> tapOpen(WidgetTester tester, String? url) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => openExternalLink(context, url),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
    }

    testWidgets('opens a valid link in the browser', (tester) async {
      Uri? opened;
      urlOpener = (uri) async {
        opened = uri;
        return true;
      };
      await tapOpen(tester, 'https://www.craigslist.org/view/d/x/1');
      expect(opened?.host, 'www.craigslist.org');
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a malformed link never reaches the launcher', (tester) async {
      var called = false;
      urlOpener = (uri) async => called = true;
      await tapOpen(tester, 'javascript:alert(1)');
      expect(called, isFalse);
      expect(find.textContaining("doesn't look valid"), findsOneWidget);
    });

    testWidgets('a launcher failure shows a message instead of crashing', (
      tester,
    ) async {
      urlOpener = (uri) async =>
          throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
      await tapOpen(tester, 'https://example.com/a');
      expect(tester.takeException(), isNull);
      expect(find.textContaining("Couldn't open a browser"), findsOneWidget);
      expect(find.text('Copy link'), findsOneWidget);
    });
  });

  group('offline', () {
    final offline = MockClient(
      (_) async => throw http.ClientException('Failed host lookup'),
    );

    test('scraping reports a friendly network error', () async {
      final fetcher = ListingFetchService(
        client: offline,
        maxAttempts: 1,
        policy: RequestPolicy.unthrottled,
      );
      await expectLater(
        fetcher.fetchRaw(Uri.parse('https://www.craigslist.org/search')),
        throwsA(
          isA<ListingFetchException>()
              .having((e) => e.isNetwork, 'isNetwork', isTrue)
              .having((e) => e.message, 'message', contains('offline'))
              .having((e) => e.message, 'message', isNot(contains('Socket'))),
        ),
      );
    });

    test(
      'a pasted listing still gets parsed when Gemini is unreachable',
      () async {
        GeminiException? reason;
        final lead =
            await GeminiService(
              apiKey: 'key',
              client: offline,
              minRequestInterval: Duration.zero,
            ).structureListing(
              r'Need a plumber in Austin TX to fix a leak, $90',
              onFallback: (error) => reason = error,
            );
        expect(lead, isNotNull);
        expect(lead!.price, 90);
        expect(reason?.isNetwork, isTrue);
        expect(reason?.message, contains('offline'));
      },
    );
  });
}
