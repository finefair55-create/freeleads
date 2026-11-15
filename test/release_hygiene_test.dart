import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The Gemini key is passed with --dart-define-from-file; it must never
  // ship inside the app bundle where anyone can unzip it.
  test('no secrets are bundled as assets', () async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest.listAssets();
    expect(assets, contains('assets/zip_centroids.csv'));
    expect(assets.where((path) => path.contains('secret')), isEmpty);
  });
}
