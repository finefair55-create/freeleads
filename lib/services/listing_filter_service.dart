/// On-device keyword gate. No plugins and no Firebase.
class ListingFilterService {
  ListingFilterService({Set<String>? keywords})
    : keywords = keywords ?? defaultKeywords;

  final Set<String> keywords;

  static const defaultKeywords = {
    'job',
    'hire',
    'hiring',
    'service',
    'repair',
    'plumber',
    'electrician',
    'cleaner',
    'moving',
    'nanny',
    'tutor',
    'available',
    'needed',
    'wanted',
    'fix',
    'garden',
  };

  /// Related terms so a "plumber" also matches "leak" or "water heater".
  static const _tradeSynonyms = <String, Set<String>>{
    'plumb': {
      'plumb',
      'leak',
      'drain',
      'pipe',
      'faucet',
      'toilet',
      'sewer',
      'water heater',
      'clog',
    },
    'electric': {
      'electric',
      'wiring',
      'outlet',
      'breaker',
      'panel',
      'light fixture',
      'ev charger',
    },
    'hvac': {
      'hvac',
      'furnace',
      'air condition',
      'a/c',
      'heat pump',
      'duct',
      'thermostat',
    },
    'handy': {
      'handyman',
      'handy man',
      'odd job',
      'repair',
      'fix',
      'install',
      'assemble',
    },
    'clean': {
      'clean',
      'maid',
      'housekeep',
      'janitor',
      'move-out',
      'deep clean',
    },
    'mov': {'mover', 'moving', 'haul', 'load', 'unload', 'junk removal'},
    'paint': {'paint', 'drywall', 'stain', 'primer'},
    'landscap': {
      'landscap',
      'lawn',
      'yard',
      'garden',
      'mow',
      'tree',
      'hedge',
      'sprinkler',
    },
    'carpent': {'carpent', 'cabinet', 'deck', 'framing', 'trim', 'woodwork'},
    'roof': {'roof', 'shingle', 'gutter'},
    'tutor': {'tutor', 'lesson', 'homework', 'teacher'},
  };

  /// Keywords for a profession, e.g. "plumber" → {plumber, leak, drain, …}.
  static Set<String> professionTerms(String profession) {
    final words = profession
        .toLowerCase()
        .split(RegExp(r'[^a-z]+'))
        .where((word) => word.length >= 3)
        .toSet();
    final terms = <String>{...words};
    for (final word in words) {
      for (final entry in _tradeSynonyms.entries) {
        if (word.startsWith(entry.key) || entry.key.startsWith(word)) {
          terms.addAll(entry.value);
        }
      }
    }
    return terms;
  }

  /// A filter that requires a profession-related term.
  factory ListingFilterService.forProfession(String profession) {
    final terms = professionTerms(profession);
    return ListingFilterService(keywords: terms.isEmpty ? null : terms);
  }

  bool matches(String rawText) {
    final haystack = rawText.toLowerCase();
    return keywords.any(haystack.contains);
  }

  List<String> filter(Iterable<String> listings) {
    return listings.where(matches).toList(growable: false);
  }
}
