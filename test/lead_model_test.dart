import 'package:flutter_test/flutter_test.dart';
import 'package:free_leads/models/lead.dart';

void main() {
  test('toJson/fromJson round-trips every field', () {
    final lead = Lead(
      id: 'cl-aaa111',
      title: 'Water heater leak',
      description: 'Leaking from the bottom.',
      category: 'Plumbing',
      location: 'Oakland',
      zipCode: '94609',
      price: 85,
      budget: r'$85/hr',
      contactInfo: '510-555-0142',
      sourceUrl: 'https://www.craigslist.org/view/d/x/aaa111',
      source: LeadSource.scraped,
      createdAt: DateTime.utc(2026, 10, 15, 12),
      postedAt: DateTime.utc(2026, 10, 14, 16, 15),
      isFavorite: true,
    );
    final copy = Lead.fromJson(lead.toJson());
    expect(copy.toJson(), lead.toJson());
    expect(copy.id, 'cl-aaa111');
    expect(copy.isFavorite, isTrue);
    expect(copy.source, LeadSource.scraped);
  });

  test('cloud JSON leaves out id, timestamps and local flags', () {
    final json = const Lead(
      id: 'x',
      title: 't',
      description: 'd',
      category: 'c',
      location: 'l',
      isFavorite: true,
    ).toCloudJson();
    expect(json.containsKey('id'), isFalse);
    expect(json.containsKey('isFavorite'), isFalse);
    expect(json.containsKey('createdAt'), isFalse);
  });

  test('accepts Gemini-style budget strings and legacy documents', () {
    final lead = Lead.fromJson({
      'title': 'Paint fence',
      'price/budget': r'$1,250 flat',
      'zipCode': '94110-1234',
      'source': 'internal',
    });
    expect(lead.price, 1250);
    expect(lead.budget, r'$1,250 flat');
    expect(lead.budgetLabel, r'$1,250 flat');
    expect(lead.zipCode, '94110');
    expect(lead.category, 'General');

    final legacy = Lead.fromJson({'title': 'Old', 'price': '45'});
    expect(legacy.price, 45);
    expect(legacy.budgetLabel, r'$45');
    expect(legacy.source, LeadSource.internal);
  });

  test('zero or missing amounts are treated as no price', () {
    expect(Lead.parsePrice(r'$0'), isNull);
    expect(Lead.parsePrice('open to quotes'), isNull);
    expect(Lead.parsePrice(null), isNull);
  });

  test('shouted titles are shown in sentence case', () {
    expect(
      Lead.tidyTitle('DO YOU FIX APPLIANCES? WE NEED TECHS NOW !!!'),
      'Do you fix appliances? We need techs now!',
    );
    expect(
      Lead.tidyTitle('***NEED HVAC TECH ASAP*** SATURDAY'),
      'Need HVAC tech ASAP Saturday',
    );
    expect(
      Lead.tidyTitle("I'M MOVING TO AUSTIN TX"),
      "I'm moving to austin TX",
    );
    expect(
      Lead.tidyTitle("I'M MOVING TO AUSTIN TX", properNouns: ['Austin']),
      "I'm moving to Austin TX",
    );
    expect(
      Lead.tidyTitle('NEED IT DONE, CALL US 2BR'),
      'Need it done, call us 2BR',
      reason: '"it" and "us" are words, not acronyms here',
    );
  });

  test('titles in normal case keep their capitals', () {
    expect(
      Lead.tidyTitle('Fix my LG fridge in Brooklyn'),
      'Fix my LG fridge in Brooklyn',
    );
    expect(
      Lead.tidyTitle('Need a plumber URGENT!!!!'),
      'Need a plumber URGENT!',
    );
    expect(Lead.tidyTitle('AC repair'), 'AC repair', reason: 'too short');
    expect(Lead.tidyTitle('   '), '');
  });

  test(
    'displayTitle keeps the city capitalized and never comes back empty',
    () {
      const lead = Lead(
        id: 'x',
        title: 'PLUMBER NEEDED IN OAKLAND!!!',
        description: '',
        category: 'Plumbing',
        location: 'Oakland',
      );
      expect(lead.displayTitle, 'Plumber needed in Oakland!');
      expect(
        lead.title,
        'PLUMBER NEEDED IN OAKLAND!!!',
        reason: 'stored as is',
      );
      expect(lead.copyWith(title: '').displayTitle, 'Untitled lead');
    },
  );
}
