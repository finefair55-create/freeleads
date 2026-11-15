/// An unstructured listing as scraped from a public board, before AI cleanup.
class RawListing {
  const RawListing({
    required this.id,
    required this.url,
    required this.title,
    required this.searchZip,
    this.board = 'craigslist',
    this.priceText,
    this.neighborhood,
    this.zipCode,
    this.latitude,
    this.longitude,
    this.compensation,
    this.body,
    this.postedAt,
  });

  /// Stable id derived from the board's post id, e.g. `cl-fWCpLB6YtZTL`.
  final String id;
  final Uri url;
  final String title;

  /// ZIP the search was centered on; used when the listing states no ZIP.
  final String searchZip;
  final String board;
  final String? priceText;
  final String? neighborhood;

  /// ZIP of the posting itself: stated by the board, or the ZIP nearest
  /// its map point ([latitude], [longitude]).
  final String? zipCode;

  /// Where the board's map places the posting, when it shows one.
  final double? latitude;
  final double? longitude;
  final String? compensation;
  final String? body;
  final DateTime? postedAt;

  RawListing withDetails({
    String? title,
    String? neighborhood,
    String? zipCode,
    double? latitude,
    double? longitude,
    String? compensation,
    String? body,
    DateTime? postedAt,
  }) {
    return RawListing(
      id: id,
      url: url,
      title: title ?? this.title,
      searchZip: searchZip,
      board: board,
      priceText: priceText,
      neighborhood: neighborhood ?? this.neighborhood,
      zipCode: zipCode ?? this.zipCode,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      compensation: compensation ?? this.compensation,
      body: body ?? this.body,
      postedAt: postedAt ?? this.postedAt,
    );
  }

  /// Plain-text rendering handed to the structuring model or local parser.
  String toPromptText({int maxBodyChars = 2500}) {
    final buffer = StringBuffer()..writeln('Title: $title');
    if (priceText != null && priceText!.isNotEmpty) {
      buffer.writeln('Listed price: $priceText');
    }
    if (compensation != null && compensation!.isNotEmpty) {
      buffer.writeln('Compensation: $compensation');
    }
    if (neighborhood != null && neighborhood!.isNotEmpty) {
      buffer.writeln('Area: $neighborhood');
    }
    if (zipCode != null && zipCode!.isNotEmpty) {
      buffer.writeln('ZIP: $zipCode');
    }
    final text = body?.trim() ?? '';
    if (text.isNotEmpty) {
      buffer
        ..writeln('Body:')
        ..writeln(
          text.length > maxBodyChars
              ? '${text.substring(0, maxBodyChars)}…'
              : text,
        );
    }
    return buffer.toString().trim();
  }
}
