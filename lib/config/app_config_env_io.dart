import 'dart:io';

String geminiApiKeyFromEnvironment() {
  return Platform.environment['GEMINI_API_KEY'] ?? '';
}
