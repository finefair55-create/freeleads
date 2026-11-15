import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_leads/models/lead.dart';
import 'package:free_leads/models/raw_listing.dart';
import 'package:free_leads/services/gemini_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fakes.dart';

RawListing raw(String id, String title, {String? body}) => RawListing(
  id: id,
  url: Uri.parse('https://www.craigslist.org/view/d/x/$id'),
  title: title,
  searchZip: '94110',
  neighborhood: 'oakland',
  body: body,
);

GeminiService service(MockClient client, {int batchSize = 8}) => GeminiService(
  apiKey: 'test-key',
  model: 'gemini-test',
  client: client,
  batchSize: batchSize,
  minRequestInterval: Duration.zero,
);

void main() {
  test('sends a schema-constrained request and maps results by id', () async {
    late http.Request sent;
    final gemini = service(
      MockClient((request) async {
        sent = request;
        return judgeListings(request);
      }),
    );

    final result = await gemini.structureBatch([
      raw('cl-1', 'Water heater leak', body: 'Call 510-555-0142'),
      raw('cl-2', 'EARN \$5000/WEEK FROM HOME'),
    ], profession: 'plumber');

    expect(
      sent.url.toString(),
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent',
    );
    expect(sent.headers['x-goog-api-key'], 'test-key');
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    final config = body['generationConfig'] as Map<String, dynamic>;
    expect(config['responseMimeType'], 'application/json');
    expect(config['responseJsonSchema'], isA<Map<String, dynamic>>());
    expect(promptListings(sent).map((item) => item['id']), ['cl-1', 'cl-2']);

    expect(result.rejectedIds, {'cl-2'});
    expect(result.kept, hasLength(1));
    final lead = result.kept.single;
    expect(lead.id, 'cl-1');
    expect(lead.source, LeadSource.scraped);
    expect(lead.contactInfo, '510-555-0142');
    expect(lead.budget, r'$85/hr');
    expect(lead.price, 85);
    expect(lead.zipCode, '94110', reason: 'falls back to the search ZIP');
    expect(lead.sourceUrl, 'https://www.craigslist.org/view/d/x/cl-1');
  });

  test("the board's ZIP wins over one the model read from the text", () async {
    final gemini = service(
      MockClient((request) async {
        final judged = jsonDecode(judgeListings(request).body);
        final text =
            judged['candidates'][0]['content']['parts'][0]['text'] as String;
        final listings = (jsonDecode(text) as Map)['listings'] as List;
        for (final item in listings) {
          // E.g. a stray five-digit number in the body.
          (item as Map)['zipCode'] = '10001';
        }
        return geminiResponse({'listings': listings});
      }),
    );
    final result = await gemini.structureBatch([
      raw('cl-1', 'Water heater leak').withDetails(zipCode: '94609'),
      raw('cl-2', 'Faucet drip'),
    ], profession: 'plumber');
    final zips = {for (final lead in result.kept) lead.id: lead.zipCode};
    expect(zips, {'cl-1': '94609', 'cl-2': '10001'});
  });

  test('batches listings to save free-tier requests', () async {
    var calls = 0;
    final gemini = service(
      MockClient((request) async {
        calls++;
        return judgeListings(request);
      }),
      batchSize: 2,
    );
    final result = await gemini.structureBatch([
      for (var i = 0; i < 5; i++) raw('cl-$i', 'Leak $i'),
    ], profession: 'plumber');
    expect(calls, 3);
    expect(result.kept, hasLength(5));
  });

  test(
    'ignores ids the model invents and leaves skipped ones unjudged',
    () async {
      final gemini = service(
        MockClient(
          (_) async => geminiResponse({
            'listings': [
              {
                'id': 'made-up',
                'keep': true,
                'title': 'x',
                'description': 'x',
                'category': 'Other',
              },
            ],
          }),
        ),
      );
      final result = await gemini.structureBatch([
        raw('cl-1', 'Leak'),
      ], profession: 'plumber');
      expect(result.kept, isEmpty);
      expect(result.rejectedIds, isEmpty);
    },
  );

  test('retries a 429 using the server retryDelay', () async {
    var calls = 0;
    final gemini = service(
      MockClient((request) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            jsonEncode({
              'error': {
                'code': 429,
                'message': 'Resource exhausted',
                'details': [
                  {
                    '@type': 'type.googleapis.com/google.rpc.RetryInfo',
                    'retryDelay': '0s',
                  },
                ],
              },
            }),
            429,
          );
        }
        return judgeListings(request);
      }),
    );
    final result = await gemini.structureBatch([
      raw('cl-1', 'Leak'),
    ], profession: 'plumber');
    expect(calls, 2);
    expect(result.kept, hasLength(1));
  });

  test('keeps earlier batches when a later one fails', () async {
    var calls = 0;
    final gemini = service(
      MockClient((request) async {
        calls++;
        return calls == 1
            ? judgeListings(request)
            : http.Response('{"error":{"message":"bad"}}', 400);
      }),
      batchSize: 1,
    );
    final result = await gemini.structureBatch([
      raw('cl-1', 'Leak'),
      raw('cl-2', 'Clog'),
      raw('cl-3', 'Drip'),
    ], profession: 'plumber');
    expect(result.kept.map((lead) => lead.id), ['cl-1']);
    expect(result.unprocessed.map((listing) => listing.id), ['cl-2', 'cl-3']);
    expect(result.error, isA<GeminiException>());
  });

  test('pasted listing judged as spam returns null', () async {
    final gemini = service(
      MockClient((request) async => judgeListings(request)),
    );
    expect(await gemini.structureListing('WORK FROM HOME today'), isNull);
    expect(
      await gemini.structureListing('Need a plumber for a leak'),
      isA<Lead>().having((lead) => lead.source, 'source', LeadSource.parsed),
    );
  });
}
