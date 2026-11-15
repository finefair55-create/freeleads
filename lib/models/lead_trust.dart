/// How much a lead can be trusted, from Gemini's review and on-device
/// red-flag checks (see `LeadGrader`). Ordered best to worst.
enum LeadTrust {
  /// Reads like a genuine customer with a clear job.
  reliable,

  /// Vague, missing key details, or one red flag. Worth a careful look.
  questionable,

  /// Several scam or spam signals, but possibly real.
  spam;

  static LeadTrust? fromName(Object? name) {
    for (final value in values) {
      if (value.name == name) {
        return value;
      }
    }
    return null;
  }

  String get label => switch (this) {
    LeadTrust.reliable => 'Reliable',
    LeadTrust.questionable => 'Questionable',
    LeadTrust.spam => 'Possible spam',
  };

  /// The less trustworthy of the two.
  LeadTrust worst(LeadTrust other) => index >= other.index ? this : other;
}
