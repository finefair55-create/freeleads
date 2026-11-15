import 'app_config_env_stub.dart'
    if (dart.library.io) 'app_config_env_io.dart'
    as env;

/// Central place for keys and feature flags.
///
/// Gemini API key resolution order:
/// 1. Key the user enters in Settings (stored on-device), or a constructor
///    argument to `GeminiService` (highest priority)
/// 2. Compile-time `--dart-define=GEMINI_API_KEY=...`
/// 3. Process environment `GEMINI_API_KEY` (Linux/desktop, Android)
/// 4. [geminiApiKeyPlaceholder] below (local paste-in; keep empty in git)
class AppConfig {
  /// flutter run --dart-define=GEMINI_API_KEY=your_key
  static const geminiApiKeyFromDefine = String.fromEnvironment(
    'GEMINI_API_KEY',
    defaultValue: '',
  );

  /// Optional local override. Leave empty for production builds.
  static const geminiApiKeyPlaceholder = '';

  static String get geminiApiKey {
    if (geminiApiKeyFromDefine.isNotEmpty) {
      return geminiApiKeyFromDefine;
    }
    final fromEnv = env.geminiApiKeyFromEnvironment();
    if (fromEnv.isNotEmpty) {
      return fromEnv;
    }
    return geminiApiKeyPlaceholder;
  }

  static bool get hasGeminiKey => geminiApiKey.isNotEmpty;

  /// flutter run --dart-define=GEMINI_MODEL=gemini-3.8-flash
  ///
  /// Defaults to Flash-Lite: the cheapest current model with the most
  /// generous free-tier limits, which is plenty for listing cleanup.
  static const geminiModel = String.fromEnvironment(
    'GEMINI_MODEL',
    defaultValue: 'gemini-3.5-flash-lite',
  );

  /// How often the app re-scrapes while it is open.
  static const autoRefreshInterval = Duration(minutes: 30);

  /// How far back searches reach: postings older than this are skipped
  /// before AI review, and stored scraped leads past it are pruned
  /// (favorites are kept).
  static const scrapedLeadRetention = Duration(days: 30);

  /// Upper bound on posting pages fetched per refresh, to stay polite to the
  /// board and inside Gemini's free-tier quota.
  static const maxListingsPerRefresh = 30;
}
