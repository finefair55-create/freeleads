import 'lead.dart';

/// What the pro does and where, used to drive scraping and AI relevance.
class SearchProfile {
  const SearchProfile({
    required this.profession,
    required this.zipCode,
    this.radiusMiles = 25,
    this.boardCategories = defaultBoardCategories,
  });

  /// Craigslist gigs (`ggg`: labor, domestic, creative, etc. sub-boards)
  /// and jobs (`jjj`: skilled trades, general labor, etc.).
  static const defaultBoardCategories = ['ggg', 'jjj'];

  /// The default before jobs were added. Categories aren't user-editable,
  /// so a profile saved with exactly this is upgraded to the current one.
  static const _legacyBoardCategories = ['ggg'];
  static const radiusOptions = [5, 10, 25, 50, 100];

  final String profession;
  final String zipCode;
  final int radiusMiles;
  final List<String> boardCategories;

  bool get isValid =>
      profession.trim().isNotEmpty && Lead.normalizeZip(zipCode) == zipCode;

  /// First three ZIP digits (USPS sectional center) used to scope community
  /// leads to roughly the same metro area.
  String get zipPrefix => zipCode.length >= 3 ? zipCode.substring(0, 3) : '';

  SearchProfile copyWith({
    String? profession,
    String? zipCode,
    int? radiusMiles,
    List<String>? boardCategories,
  }) {
    return SearchProfile(
      profession: profession ?? this.profession,
      zipCode: zipCode ?? this.zipCode,
      radiusMiles: radiusMiles ?? this.radiusMiles,
      boardCategories: boardCategories ?? this.boardCategories,
    );
  }

  factory SearchProfile.fromJson(Map<String, dynamic> json) {
    final categories = json['boardCategories'];
    return SearchProfile(
      profession: json['profession'] as String? ?? '',
      zipCode: json['zipCode'] as String? ?? '',
      radiusMiles: (json['radiusMiles'] as num?)?.toInt() ?? 25,
      boardCategories:
          categories is List &&
              categories.isNotEmpty &&
              categories.join(',') != _legacyBoardCategories.join(',')
          ? categories.map((value) => value.toString()).toList()
          : defaultBoardCategories,
    );
  }

  Map<String, dynamic> toJson() => {
    'profession': profession,
    'zipCode': zipCode,
    'radiusMiles': radiusMiles,
    'boardCategories': boardCategories,
  };

  @override
  bool operator ==(Object other) =>
      other is SearchProfile &&
      other.profession == profession &&
      other.zipCode == zipCode &&
      other.radiusMiles == radiusMiles &&
      other.boardCategories.join(',') == boardCategories.join(',');

  @override
  int get hashCode =>
      Object.hash(profession, zipCode, radiusMiles, boardCategories.join(','));
}
