import '../models/lead.dart';

/// Pure-Dart fallback that structures a listing without Gemini or Firebase.
class LocalListingParser {
  Lead parse(String rawText) {
    final text = rawText.trim();
    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final title = lines.isEmpty
        ? 'Untitled listing'
        : (lines.first.length > 72
              ? '${lines.first.substring(0, 69)}…'
              : lines.first);

    return Lead(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      description: text.isEmpty ? 'No description' : text,
      category: _categoryFor(text),
      location: _locationFor(text),
      price: _priceFor(text),
      source: LeadSource.parsed,
      createdAt: DateTime.now(),
    );
  }

  String _categoryFor(String text) {
    final haystack = text.toLowerCase();
    const mapping = <String, String>{
      'plumb': 'Plumbing',
      'electric': 'Electrical',
      'wire': 'Electrical',
      'clean': 'Cleaning',
      'tutor': 'Tutoring',
      'math': 'Tutoring',
      'nanny': 'Childcare',
      'child': 'Childcare',
      'mov': 'Moving',
      'repair': 'Repair',
      'fix': 'Repair',
      'garden': 'Outdoor',
      'lawn': 'Outdoor',
      'job': 'Jobs',
      'hir': 'Jobs',
    };
    for (final entry in mapping.entries) {
      if (haystack.contains(entry.key)) {
        return entry.value;
      }
    }
    return 'General';
  }

  String _locationFor(String text) {
    final match = RegExp(
      r'\b(?:in|at|near)\s+([A-Z][A-Za-z]+(?:[ ,]+[A-Z]{2})?)',
    ).firstMatch(text);
    return match?.group(1)?.trim() ?? 'Location not listed';
  }

  double? _priceFor(String text) {
    final match = RegExp(
      r'\$\s?(\d+(?:\.\d{1,2})?)|(\d+(?:\.\d{1,2})?)\s?(?:usd|dollars?)',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) {
      return null;
    }
    return double.tryParse(match.group(1) ?? match.group(2) ?? '');
  }
}
