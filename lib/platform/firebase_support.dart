import 'package:flutter/foundation.dart';

/// FlutterFire has no Linux (or Fuchsia) implementation. Checking this is
/// Dart-only — it must happen *before* any `Firebase.*` or Firestore call.
bool get isFirebasePlatformSupported {
  if (kIsWeb) {
    return true;
  }
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      return true;
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return false;
  }
}
