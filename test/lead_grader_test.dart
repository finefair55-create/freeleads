import 'package:flutter_test/flutter_test.dart';
import 'package:free_leads/models/lead.dart';
import 'package:free_leads/services/lead_grader.dart';
import 'package:free_leads/widgets/link_opener.dart';

Lead lead({
  String title = 'Replace bathroom faucet',
  String description =
      'Two-handle faucet in the upstairs bathroom is dripping. Parts are '
      'already bought; looking for someone this Saturday morning.',
  String location = 'Park Slope',
  String? budget = r'$120',
  String? contactInfo = '718-555-0101',
  LeadTrust? trust,
  bool trustByAi = false,
}) => Lead(
  id: 'x',
  title: title,
  description: description,
  category: 'Plumbing',
  location: location,
  budget: budget,
  price: Lead.parsePrice(budget),
  contactInfo: contactInfo,
  trust: trust,
  trustReasons: trust == null ? const [] : const ['From Gemini'],
  trustByAi: trustByAi,
);

void main() {
  const grader = LeadGrader();

  group('LeadGrader.assess', () {
    test('a specific job with budget and contact is reliable', () {
      final grade = grader.assess(lead());
      expect(grade.tier, LeadTrust.reliable);
      expect(grade.reasons, contains('Budget stated'));
    });

    test('a vague post with nothing to go on is questionable', () {
      final grade = grader.assess(
        lead(
          description: 'Need help asap',
          location: 'Location not listed',
          budget: null,
          contactInfo: null,
        ),
      );
      expect(grade.tier, LeadTrust.questionable);
      expect(grade.reasons, contains('Very little detail'));
    });

    test('classic scam signals are possible spam', () {
      final grade = grader.assess(
        lead(
          title: 'PLUMBER NEEDED URGENT TODAY',
          description:
              "I'll mail a cashier's check, deposit it and send the rest by "
              'gift card. Text me on WhatsApp.',
        ),
      );
      expect(grade.tier, LeadTrust.spam);
      expect(
        grade.reasons,
        contains('Mentions payment by gift card, wire, check or crypto'),
      );
    });

    test('one red flag on an otherwise solid post is questionable', () {
      final grade = grader.assess(
        lead(
          description:
              'Kitchen sink drain is clogged and the disposal hums. We are '
              'home after 5pm on weekdays. Please message on WhatsApp first.',
        ),
      );
      expect(grade.tier, LeadTrust.questionable);
    });

    test('ordinary words do not trip the scam patterns', () {
      final grade = grader.assess(
        lead(
          description:
              'I work from home, so any weekday is fine. The kitchen faucet '
              'leaks at the base and the shutoff valve is stiff.',
        ),
      );
      expect(grade.tier, LeadTrust.reliable);
    });

    test('pay far above market is flagged', () {
      final grade = grader.assess(
        lead(budget: r'$400/hr', description: 'Fix a leak. Easy job.'),
      );
      expect(grade.reasons, contains('Pay looks too good to be true'));
      expect(grade.tier, isNot(LeadTrust.reliable));
    });
  });

  test('placeholder budgets read as Quote even on stored leads', () {
    expect(lead(budget: 'Tbd').budgetLabel, 'Quote');
    expect(lead(budget: r'$120').budgetLabel, r'$120');
  });

  group('direct customer posts', () {
    test('the ZIP the customer typed counts as a specific location', () {
      Lead post(LeadSource source) => Lead(
        id: 'p',
        title: 'Fix leaking faucet',
        description: 'Kitchen faucet drips all night, need it fixed soon.',
        category: 'Plumbing',
        location: '',
        zipCode: '10002',
        contactInfo: '212-555-0100',
        source: source,
      );
      expect(grader.assess(post(LeadSource.internal)).tier, LeadTrust.reliable);
      expect(
        grader.assess(post(LeadSource.scraped)).tier,
        LeadTrust.questionable,
        reason: "a scraped lead's ZIP may only be the search center",
      );
    });
  });

  group('LeadGrader.review', () {
    test('ungraded leads get the on-device grade', () {
      final reviewed = grader.review(lead());
      expect(reviewed.trust, LeadTrust.reliable);
      expect(reviewed.trustByAi, isFalse);
    });

    test("a hard red flag lowers Gemini's grade but keeps its reason", () {
      final reviewed = grader.review(
        lead(
          trust: LeadTrust.reliable,
          trustByAi: true,
          description:
              'Water heater replacement next week. Will pay by gift card '
              'once done, details on request.',
        ),
      );
      expect(reviewed.trust, LeadTrust.questionable);
      expect(reviewed.trustByAi, isTrue);
      expect(reviewed.trustReasons.first, 'From Gemini');
      expect(
        reviewed.trustReasons,
        contains('Mentions payment by gift card, wire, check or crypto'),
      );
    });

    test("on-device checks never raise Gemini's grade", () {
      final reviewed = grader.review(
        lead(trust: LeadTrust.spam, trustByAi: true),
      );
      expect(reviewed.trust, LeadTrust.spam);
    });
  });

  group('Lead trust and sanitizing', () {
    test('trust survives the local JSON round trip but not the cloud', () {
      final graded = grader.review(lead()).copyWith(board: 'craigslist');
      final restored = Lead.fromJson(graded.toJson());
      expect(restored.trust, LeadTrust.reliable);
      expect(restored.trustReasons, graded.trustReasons);
      expect(restored.board, 'craigslist');

      final cloud = graded.toCloudJson();
      expect(cloud.keys, isNot(contains('trust')));
      expect(cloud.keys, isNot(contains('trustReasons')));
      expect(cloud.keys, isNot(contains('board')));
    });

    test('sanitized strips invisible and bidi characters and caps length', () {
      final dirty = lead(
        title: 'Fix\u202E sink\u200B now\n\nplease',
        description: 'a' * 5000,
        budget: '  \u0007 ',
      ).sanitized();
      expect(dirty.title, 'Fix sink now please');
      expect(dirty.description.length, Lead.maxDescription);
      expect(dirty.description, endsWith('…'));
      expect(dirty.budget, isNull);
      for (final placeholder in ['Tbd', 'N/A', 'see ad', '--']) {
        expect(lead(budget: placeholder).sanitized().budget, isNull);
      }
      expect(lead(budget: r'$40/hr').sanitized().budget, r'$40/hr');
    });

    test('old scraped leads without a board still read as Craigslist', () {
      final legacy = Lead.fromJson({
        'title': 't',
        'description': 'd',
        'category': 'c',
        'location': 'l',
        'source': 'scraped',
      });
      expect(legacy.boardId, 'craigslist');
      expect(legacy.trust, isNull);
    });
  });

  group('contactActions', () {
    test('builds call, text and email from the contact text only', () {
      final actions = contactActions(
        'Call (718) 555-0101 or mail jo.smith+jobs@example.com',
        subject: 'Re: Fix sink',
      );
      expect(actions.map((a) => a.label), ['Call', 'Text', 'Email']);
      expect(actions[0].uri.toString(), 'tel:+17185550101');
      expect(actions[1].uri.toString(), 'sms:+17185550101');
      expect(
        actions[2].uri.toString(),
        'mailto:jo.smith+jobs@example.com?subject=Re%3A%20Fix%20sink',
      );
    });

    test('ignores text that is not a US phone number', () {
      expect(contactActions('Reply via craigslist'), isEmpty);
      expect(contactActions('order #123456789012345'), isEmpty);
      expect(contactActions(null), isEmpty);
    });
  });
}
