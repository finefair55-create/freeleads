import 'dart:convert';
import 'dart:io';

import 'package:free_leads/services/zip_geocoder.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Pulls the listings array the service embeds in its user prompt.
List<Map<String, dynamic>> promptListings(http.Request request) {
  final body = jsonDecode(request.body) as Map<String, dynamic>;
  final text =
      (((body['contents'] as List).first as Map)['parts'] as List).first['text']
          as String;
  final json = text.substring(text.indexOf('['));
  return (jsonDecode(json) as List).cast<Map<String, dynamic>>();
}

/// Builds a Gemini `generateContent` response whose text is [payload].
http.Response geminiResponse(Object payload) {
  return http.Response(
    jsonEncode({
      'candidates': [
        {
          'content': {
            'role': 'model',
            'parts': [
              {'text': jsonEncode(payload)},
            ],
          },
          'finishReason': 'STOP',
        },
      ],
    }),
    200,
    headers: {'content-type': 'application/json'},
  );
}

/// Simulated Gemini judgement: rejects anything that reads like a
/// work-from-home pitch, keeps and structures the rest.
http.Response judgeListings(http.Request request) {
  return geminiResponse({
    'listings': [
      for (final item in promptListings(request))
        if ((item['text'] as String).contains('FROM HOME'))
          {
            'id': item['id'],
            'keep': false,
            'rejectReason': 'work-from-home spam',
            'title': '',
            'description': '',
            'category': 'Other',
          }
        else
          {
            'id': item['id'],
            'keep': true,
            'title': 'Repair leaking water heater',
            'description': 'Licensed plumber needed this week.',
            'budget': r'$85/hr',
            'price': 85,
            'contactInfo': (item['text'] as String).contains('510-555-0142')
                ? '510-555-0142'
                : null,
            'category': 'Plumbing',
            'zipCode': null,
            'location': 'Oakland',
            'trust': 'reliable',
            'trustReason': 'Clear scope and pay from a homeowner.',
          },
    ],
  });
}

/// A few Bay Area ZIPs and one in New York.
const testZipCsv = '''
# comment
94110,37.750,-122.415
94103,37.773,-122.411
94609,37.834,-122.264
10001,40.750,-73.997
bad,line
''';

/// A loaded [ZipGeocoder] over [testZipCsv], so tests never read the real
/// table (which widget tests can't wait out).
ZipGeocoder testGeocoder() =>
    ZipGeocoder.fromPoints(ZipGeocoder.parse(testZipCsv));

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

/// Serves the Craigslist fixtures and routes Gemini calls to [gemini].
MockClient fakeInternet({
  http.Response Function(http.Request request)? gemini,
  List<Uri>? log,
}) {
  return MockClient((request) async {
    log?.add(request.url);
    final url = request.url;
    if (url.host == 'generativelanguage.googleapis.com') {
      return (gemini ?? judgeListings)(request);
    }
    if (url.host == 'www.craigslist.org' && url.path == '/search') {
      return http.Response(
        fixture('craigslist_search.html'),
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    }
    if (url.path.endsWith('/aaa111')) {
      return http.Response(
        fixture('craigslist_posting.html'),
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    }
    return http.Response('not found', 404);
  });
}
