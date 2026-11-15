import 'lead_trust.dart';

export 'lead_trust.dart';

/// A unit of work a pro can respond to: a scraped board listing, a listing
/// pasted into the parser, or an order posted natively in the app.
class Lead {
  const Lead({
    required this.id,
    required this.title,
    required this.description,
    required this.category,
    required this.location,
    this.zipCode = '',
    this.price,
    this.budget,
    this.contactInfo,
    this.sourceUrl,
    this.authorId,
    this.source = LeadSource.internal,
    this.createdAt,
    this.postedAt,
    this.isFavorite = false,
    this.board,
    this.trust,
    this.trustReasons = const [],
    this.trustByAi = false,
  });

  final String id;
  final String title;
  final String description;
  final String category;
  final String location;

  /// Five-digit US ZIP the job is in (or the ZIP the search was run from
  /// when the listing does not state one).
  final String zipCode;

  /// Numeric amount used for sorting and stats, when the budget has one.
  final double? price;

  /// Budget exactly as the poster phrased it, e.g. "\$25/hr" or "make offer".
  final String? budget;

  /// Phone, email, or reply instructions taken from the listing itself.
  final String? contactInfo;

  /// Original listing URL for scraped leads.
  final String? sourceUrl;

  /// Firebase uid of the poster for community leads.
  final String? authorId;

  final LeadSource source;

  /// When this lead entered FreeLeads (scraped, parsed, or posted).
  final DateTime? createdAt;

  /// When the original listing was published on its board.
  final DateTime? postedAt;

  /// Device-local flag; never written to Firestore.
  final bool isFavorite;

  /// Listing source id for scraped leads (e.g. `craigslist`), see
  /// `ListingSource.id`. Null for posted and imported leads.
  final String? board;

  /// Trust tier; null until graded. Device-local, like [trustReasons].
  final LeadTrust? trust;

  /// Short, user-facing reasons for [trust].
  final List<String> trustReasons;

  /// Whether Gemini graded this lead (otherwise on-device checks did).
  final bool trustByAi;

  /// [board], defaulting to Craigslist for scraped leads stored before
  /// leads carried a board.
  String? get boardId =>
      board ?? (source == LeadSource.scraped ? 'craigslist' : null);

  /// Best timestamp for ordering a feed.
  DateTime get sortTime =>
      postedAt ?? createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  /// [title] as shown in the app: shouting tamed by [tidyTitle], with place
  /// names from [location] keeping their capitals. The stored title is left
  /// as posted, since the trust grader reads its capitals and punctuation.
  String get displayTitle {
    final text = tidyTitle(
      title,
      properNouns: location == _noLocation
          ? const []
          : RegExp(r"[A-Z][A-Za-z'’-]+")
                .allMatches(location)
                .map((match) => match.group(0)!),
    );
    return text.isEmpty ? 'Untitled lead' : text;
  }

  /// Placeholder location the scraper stores when a listing names none.
  static const _noLocation = 'Location not listed';

  /// Short words kept in capitals when a shouted title is sentence-cased.
  /// "IT" and "US" are left out: in a title they're usually "it" and "us".
  static final _acronyms = {
    ...'AC ADA ADU ASAP ATM BBQ BR CDL CPR DC DIY DMV DVD EPA EV GE GED GPS '
            'HOA HVAC IKEA LED LG LLC NYC OSHA PC PVC RV SUV TV UPS USA USPS '
            'WIFI'
        .split(' '),
    // US states, minus the ones that are also English words (IN, OR, ME).
    ...'AK AL AR AZ CA CT DE FL GA IA KS KY LA MA MD MI MN MO MS MT NC ND NE '
            'NH NJ NM NV NY PA RI SC SD TN TX UT VA VT WA WI WV WY'
        .split(' '),
  };

  /// Weekdays and months ("may" is left out: it's usually the verb).
  static final _capitalized = {
    ...'monday tuesday wednesday thursday friday saturday sunday january '
            'february march april june july august september october '
            'november december'
        .split(' '),
  };

  /// Tones down a listing title for display: drops decoration like `***`,
  /// collapses `!!!` and `?!?` into one mark, and turns an ALL-CAPS title
  /// into sentence case, keeping acronyms ([_acronyms]), "I", weekdays,
  /// months and any [properNouns] (e.g. the lead's city) capitalized.
  /// Titles in normal case keep their wording and capitals.
  ///
  /// It only re-cases and tidies; rewording a title is Gemini's job.
  static String tidyTitle(
    String title, {
    Iterable<String> properNouns = const [],
  }) {
    var text = title
        .replaceAll(RegExp(r'[*~=_#]{2,}'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'\s+(?=[!?.,;:])'), '')
        .replaceAllMapped(RegExp(r'([!?])[!?1]*[!?]'), (m) => m[1]!)
        .trim();
    final letters = text.replaceAll(RegExp('[^A-Za-z]'), '');
    final upper = letters.replaceAll(RegExp('[^A-Z]'), '').length;
    if (letters.length < 6 || upper <= letters.length * 0.6) {
      return text;
    }
    final names = {for (final name in properNouns) name.toLowerCase(): name};
    text = text.replaceAllMapped(RegExp(r"[A-Za-z]+(?:['’][A-Za-z]+)?"), (m) {
      final word = m[0]!;
      final lower = word.toLowerCase();
      if (_acronyms.contains(word.toUpperCase())) {
        return word.toUpperCase();
      }
      if (lower == 'i' || lower.startsWith("i'") || lower.startsWith('i’')) {
        return 'I${lower.substring(1)}';
      }
      if (names[lower] case final name?) {
        return name;
      }
      if (_capitalized.contains(lower)) {
        return '${lower[0].toUpperCase()}${lower.substring(1)}';
      }
      return lower;
    });
    // Capitalize the first letter of each sentence.
    return text.replaceAllMapped(
      RegExp(r'(^|[.!?]\s+)([a-z])'),
      (m) => '${m[1]}${m[2]!.toUpperCase()}',
    );
  }

  /// Display label for the budget, preferring the poster's wording.
  String get budgetLabel {
    final text = budget?.trim();
    // Leads stored before placeholders were stripped can still hold "TBD".
    if (text != null && text.isNotEmpty && !_isPlaceholder(text)) {
      return text;
    }
    final amount = price;
    if (amount == null) {
      return 'Quote';
    }
    return '\$${amount.toStringAsFixed(amount % 1 == 0 ? 0 : 2)}';
  }

  Lead copyWith({
    String? id,
    String? title,
    String? description,
    String? category,
    String? location,
    String? zipCode,
    double? price,
    String? budget,
    String? contactInfo,
    String? sourceUrl,
    String? authorId,
    LeadSource? source,
    DateTime? createdAt,
    DateTime? postedAt,
    bool? isFavorite,
    String? board,
    LeadTrust? trust,
    List<String>? trustReasons,
    bool? trustByAi,
  }) {
    return Lead(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      category: category ?? this.category,
      location: location ?? this.location,
      zipCode: zipCode ?? this.zipCode,
      price: price ?? this.price,
      budget: budget ?? this.budget,
      contactInfo: contactInfo ?? this.contactInfo,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      authorId: authorId ?? this.authorId,
      source: source ?? this.source,
      createdAt: createdAt ?? this.createdAt,
      postedAt: postedAt ?? this.postedAt,
      isFavorite: isFavorite ?? this.isFavorite,
      board: board ?? this.board,
      trust: trust ?? this.trust,
      trustReasons: trustReasons ?? this.trustReasons,
      trustByAi: trustByAi ?? this.trustByAi,
    );
  }

  /// Categories Gemini files listings under, also offered when posting, so
  /// both kinds of lead share the feed's category chips.
  static const categories = [
    'Plumbing',
    'Electrical',
    'HVAC',
    'Handyman',
    'Carpentry',
    'Painting',
    'Roofing',
    'Flooring',
    'Landscaping',
    'Cleaning',
    'Moving',
    'Construction',
    'Appliance Repair',
    'Auto',
    'Tech Support',
    'Tutoring',
    'Childcare',
    'Pet Care',
    'Events',
    'Other',
  ];

  /// Field limits, matching `firestore.rules`.
  static const maxTitle = 120;
  static const maxDescription = 4000;
  static const maxShortField = 120;
  static const maxBudget = 80;
  static const maxContact = 200;

  /// Copy with invisible control and bidi-override characters removed and
  /// fields capped to sane lengths. Listing text comes from strangers, so
  /// run this on everything scraped, imported or received.
  Lead sanitized() {
    return Lead(
      id: id,
      title: cleanText(title, maxLength: maxTitle, singleLine: true),
      description: cleanText(description, maxLength: maxDescription),
      category: cleanText(category, maxLength: 60, singleLine: true),
      location: cleanText(location, maxLength: maxShortField, singleLine: true),
      zipCode: zipCode,
      price: price != null && price!.isFinite && price! >= 0 ? price : null,
      budget: _isPlaceholder(budget) ? null : _cleanOptional(budget, maxBudget),
      contactInfo: _cleanOptional(contactInfo, maxContact),
      sourceUrl: sourceUrl,
      authorId: authorId,
      source: source,
      createdAt: createdAt,
      postedAt: postedAt,
      isFavorite: isFavorite,
      board: board,
      trust: trust,
      trustReasons: [
        for (final reason in trustReasons.take(5))
          cleanText(reason, maxLength: 140, singleLine: true),
      ],
      trustByAi: trustByAi,
    );
  }

  static final _invisible = RegExp(
    '[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F'
    '\u200B-\u200F\u202A-\u202E\u2060-\u2069\uFEFF]',
  );

  /// Strips control, zero-width and bidi-override characters (which can
  /// make text display differently from what it says), trims, and caps the
  /// length.
  static String cleanText(
    String value, {
    required int maxLength,
    bool singleLine = false,
  }) {
    var text = value.replaceAll(_invisible, '');
    text = singleLine
        ? text.replaceAll(RegExp(r'\s+'), ' ')
        : text
              .replaceAll(RegExp(r'[ \t]+\n'), '\n')
              .replaceAll(RegExp(r'\n{3,}'), '\n\n');
    text = text.trim();
    if (text.length > maxLength) {
      var end = maxLength - 1;
      // Don't split an emoji's surrogate pair.
      final last = text.codeUnitAt(end - 1);
      if (last >= 0xD800 && last <= 0xDBFF) {
        end--;
      }
      text = '${text.substring(0, end).trimRight()}…';
    }
    return text;
  }

  /// "TBD", "n/a", "see ad" and the like say nothing about pay.
  static bool _isPlaceholder(String? budget) => RegExp(
    r'^\s*(?:tbd|tba|n/?a|none|see (?:ad|post|listing)|-+|\?+)\s*\.?\s*$',
    caseSensitive: false,
  ).hasMatch(budget ?? '');

  static String? _cleanOptional(String? value, int maxLength) {
    if (value == null) {
      return null;
    }
    final text = cleanText(value, maxLength: maxLength, singleLine: true);
    return text.isEmpty ? null : text;
  }

  factory Lead.fromJson(Map<String, dynamic> json, {String? id}) {
    final budgetValue = json['budget'] ?? json['price/budget'];
    return Lead(
      id: id ?? json['id'] as String? ?? '',
      title: _string(json['title']) ?? '',
      description: _string(json['description']) ?? '',
      category: _string(json['category']) ?? 'General',
      location: _string(json['location']) ?? '',
      zipCode: normalizeZip(_string(json['zipCode'])) ?? '',
      price: parsePrice(json['price']) ?? parsePrice(budgetValue),
      budget: budgetValue is num ? null : _string(budgetValue),
      contactInfo: _string(json['contactInfo']),
      sourceUrl: _string(json['sourceUrl']),
      authorId: _string(json['authorId']),
      source: LeadSource.fromName(json['source'] as String?),
      createdAt: _parseDate(json['createdAt']),
      postedAt: _parseDate(json['postedAt']),
      isFavorite: json['isFavorite'] == true,
      board: _string(json['board']),
      trust: LeadTrust.fromName(json['trust']),
      trustReasons: json['trustReasons'] is List
          ? [
              for (final reason in json['trustReasons'] as List)
                if (reason is String && reason.trim().isNotEmpty) reason,
            ]
          : const [],
      trustByAi: json['trustByAi'] == true,
    );
  }

  /// Full local representation (Hive). Use [toCloudJson] for Firestore.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      ...toCloudJson(),
      'createdAt': createdAt?.toIso8601String(),
      'isFavorite': isFavorite,
      'board': board,
      'trust': trust?.name,
      'trustReasons': trustReasons,
      'trustByAi': trustByAi,
    };
  }

  /// Shared fields only: no id (the document id), no device-local flags or
  /// trust grades (each device grades for itself) and no timestamp (the Firestore service stamps a server timestamp).
  Map<String, dynamic> toCloudJson() {
    return {
      'title': title,
      'description': description,
      'category': category,
      'location': location,
      'zipCode': zipCode,
      'price': price,
      'budget': budget,
      'contactInfo': contactInfo,
      'sourceUrl': sourceUrl,
      'authorId': authorId,
      'source': source.name,
      'postedAt': postedAt?.toIso8601String(),
    };
  }

  static String? _string(dynamic value) {
    if (value == null) {
      return null;
    }
    final text = value.toString().trim();
    if (text.isEmpty || text.toLowerCase() == 'null') {
      return null;
    }
    return text;
  }

  /// Pulls the first amount out of values like 120, "120", "\$1,200",
  /// or "\$25/hr". Returns null when there is no positive number.
  static double? parsePrice(dynamic value) {
    if (value is num) {
      return value > 0 ? value.toDouble() : null;
    }
    if (value is String) {
      final match = RegExp(r'\d[\d,]*(?:\.\d+)?').firstMatch(value);
      if (match == null) {
        return null;
      }
      final amount = double.tryParse(match.group(0)!.replaceAll(',', ''));
      return amount != null && amount > 0 ? amount : null;
    }
    return null;
  }

  /// Returns the 5-digit ZIP inside [value] (accepts ZIP+4), or null.
  static String? normalizeZip(String? value) {
    if (value == null) {
      return null;
    }
    return RegExp(r'\b(\d{5})(?:-\d{4})?\b').firstMatch(value)?.group(1);
  }

  static DateTime? _parseDate(dynamic value) {
    if (value is DateTime) {
      return value;
    }
    if (value is String) {
      return DateTime.tryParse(value);
    }
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }
    try {
      // Firestore Timestamp, without importing cloud_firestore here.
      return (value as dynamic).toDate() as DateTime?;
    } catch (_) {
      return null;
    }
  }
}

enum LeadSource {
  /// Pulled from a public board (Craigslist) by the on-device scraper.
  scraped,

  /// Pasted into the parser by the user.
  parsed,

  /// Posted directly in FreeLeads by a customer.
  internal;

  static LeadSource fromName(String? name) {
    return LeadSource.values.firstWhere(
      (value) => value.name == name,
      orElse: () => LeadSource.internal,
    );
  }

  /// Badge label for leads without a board (see `boardLabel`).
  String get label => switch (this) {
    LeadSource.scraped => 'Listing',
    LeadSource.parsed => 'Imported',
    LeadSource.internal => 'Direct Customer',
  };
}
