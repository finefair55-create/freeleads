// ignore_for_file: avoid_print
// Live smoke test against real Craigslist + Gemini. Not part of `flutter test`
// (lives outside test/). Run:
//   flutter test tool/live_smoke_test.dart --dart-define-from-file=secrets.json
import 'package:flutter_test/flutter_test.dart';
import 'package:free_leads/config/app_config.dart';
import 'package:free_leads/models/search_profile.dart';
import 'package:free_leads/services/listing_pipeline.dart';

void main() {
  test('live refresh', () async {
    expect(AppConfig.hasGeminiKey, isTrue, reason: 'pass secrets.json');
    const profession = String.fromEnvironment(
      'PROFESSION',
      defaultValue: 'plumber',
    );
    const zip = String.fromEnvironment('ZIP', defaultValue: '10001');
    final report = await ListingPipeline().run(
      const SearchProfile(profession: profession, zipCode: zip),
      maxNew: 12,
    );
    print(
      'model=${AppConfig.geminiModel} found=${report.found} '
      'usedAi=${report.usedAi} kept=${report.leads.length} '
      'rejected=${report.rejectedIds.length}',
    );
    if (report.warning != null) print('warning: ${report.warning}');
    for (final lead in report.leads) {
      print(
        '- [${lead.trust?.label} ${lead.trustByAi ? 'AI' : 'local'}] '
        '[${lead.board}/${lead.category}] ${lead.title} | '
        '${lead.budgetLabel} | zip=${lead.zipCode} | '
        'why=${lead.trustReasons.join('; ')}',
      );
    }
    expect(report.usedAi, isTrue);
    expect(report.leads.every((lead) => lead.trust != null), isTrue);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
