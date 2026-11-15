import '../models/lead.dart';

/// A trust tier with the reasons behind it.
class TrustGrade {
  const TrustGrade(this.tier, this.reasons);

  final LeadTrust tier;
  final List<String> reasons;
}

/// On-device trust grading. Works without Gemini (no key, quota used up,
/// community orders, imports) and backs Gemini up: a hard red flag found
/// here can lower Gemini's grade, but never raise it.
class LeadGrader {
  const LeadGrader();

  /// Scam patterns pros get hit with. Each is a hard red flag.
  static final _hardFlags = <(RegExp, String)>[
    (
      RegExp(
        r'gift ?cards?|wire (?:the )?(?:money|funds|transfer)|western union|'
        r'moneygram|cashier.?s check|certified check|money order|'
        r'bitcoin|crypto|usdt',
      ),
      'Mentions payment by gift card, wire, check or crypto',
    ),
    (
      RegExp(
        r'(?:verification|confirm(?:ation)?|google voice) code|'
        r'code (?:i|we) (?:sent|send)',
      ),
      'Asks for a verification code',
    ),
    (
      RegExp(r'whats ?app|telegram|signal app|wechat|kik me'),
      'Wants to move the chat to a messaging app',
    ),
    (
      RegExp(
        r'(?:registration|application|processing|upfront|up-front|starter) '
        r'(?:fee|cost|kit)|pay (?:a |the )?(?:small )?fee|send (?:a )?deposit',
      ),
      'Asks you to pay a fee up front',
    ),
    (
      RegExp(
        r'be your own boss|unlimited (?:earning|income)|passive income|'
        r'financial freedom|work from home (?:opportunity|job|position)|'
        r'(?:earn|make) \$?[\d,]+.{0,20}from home',
      ),
      'Reads like a work-from-home pitch',
    ),
    (
      RegExp(r'(?:send|share) (?:me )?(?:your )?(?:ssn|social security|bank)'),
      'Asks for personal or bank details',
    ),
  ];

  /// Grade from text signals alone.
  TrustGrade assess(Lead lead) {
    final title = lead.title;
    final text = [
      title,
      lead.description,
      lead.budget ?? '',
      lead.contactInfo ?? '',
    ].join('\n').toLowerCase();

    final concerns = [
      for (final (pattern, reason) in _hardFlags)
        if (pattern.hasMatch(text)) reason,
    ];
    final hard = concerns.length;

    var score = 0;
    final strengths = <String>[];
    if (lead.price != null || (lead.budget?.trim().isNotEmpty ?? false)) {
      score++;
      strengths.add('Budget stated');
    }
    if (lead.description.trim().length >= 120) {
      score++;
      strengths.add('Detailed description');
    } else if (lead.description.trim().length < 40) {
      score--;
      concerns.add('Very little detail');
    }
    final location = lead.location.trim().toLowerCase();
    // A scraped lead's ZIP may just be the search center, but a customer
    // posting directly typed in where the job is.
    if ((location.isNotEmpty && location != 'location not listed') ||
        (lead.source == LeadSource.internal && lead.zipCode.isNotEmpty)) {
      score++;
      strengths.add('Specific location');
    }
    if (lead.contactInfo?.trim().isNotEmpty ?? false) {
      score++;
      strengths.add('Contact details included');
    }

    final letters = title.replaceAll(RegExp(r'[^A-Za-z]'), '');
    if (letters.length >= 12 &&
        letters.replaceAll(RegExp(r'[^A-Z]'), '').length >
            letters.length * 0.6) {
      score--;
      concerns.add('Title is mostly capital letters');
    }
    if (RegExp(r'!').allMatches(text).length >= 4) {
      score--;
      concerns.add('Lots of exclamation marks');
    }
    if (RegExp(r'https?://|www\.|bit\.ly').hasMatch(text)) {
      score--;
      concerns.add('Contains outside links');
    }
    if (_implausiblePay(lead)) {
      score--;
      concerns.add('Pay looks too good to be true');
    }

    score -= 3 * hard;
    final LeadTrust tier;
    if (hard >= 2 || (hard == 1 && score < 0)) {
      tier = LeadTrust.spam;
    } else if (hard == 1 || score < 2) {
      tier = LeadTrust.questionable;
    } else {
      tier = LeadTrust.reliable;
    }
    final reasons = tier == LeadTrust.reliable ? strengths : concerns;
    return TrustGrade(
      tier,
      reasons.isEmpty && tier != LeadTrust.reliable
          ? const ['Missing budget and details']
          : reasons.take(3).toList(growable: false),
    );
  }

  /// [lead] with its final trust grade. Gemini's grade (if any) wins,
  /// except that a hard red flag found on the device can lower it.
  Lead review(Lead lead) {
    final local = assess(lead);
    final ai = lead.trustByAi ? lead.trust : null;
    if (ai == null) {
      return lead.copyWith(
        trust: local.tier,
        trustReasons: local.reasons,
        trustByAi: false,
      );
    }
    final hardConcerns = [
      for (final reason in local.reasons)
        if (_hardFlags.any((flag) => flag.$2 == reason)) reason,
    ];
    if (hardConcerns.isEmpty) {
      return lead;
    }
    // A hard flag means the local tier is questionable or worse.
    return lead.copyWith(
      trust: ai.worst(local.tier),
      trustReasons: [
        ...lead.trustReasons,
        for (final reason in hardConcerns)
          if (!lead.trustReasons.contains(reason)) reason,
      ].take(4).toList(growable: false),
    );
  }

  /// Hourly rates far above trade norms, or big flat amounts for a job
  /// described in a sentence, are classic bait.
  static bool _implausiblePay(Lead lead) {
    final price = lead.price;
    if (price == null) {
      return false;
    }
    final budget = (lead.budget ?? '').toLowerCase();
    final hourly = RegExp(r'/ ?h(?:ou)?r|per hour|an hour|hourly');
    if (hourly.hasMatch(budget) && price > 250) {
      return true;
    }
    final daily = RegExp(r'/ ?day|per day|a day|daily');
    if (daily.hasMatch(budget) && price > 1500) {
      return true;
    }
    return price >= 5000 && lead.description.trim().length < 80;
  }
}
