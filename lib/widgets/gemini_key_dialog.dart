import 'package:flutter/material.dart';

import '../app_scope.dart';

/// Lets the user add, replace or remove their own Gemini API key.
class GeminiKeyDialog extends StatefulWidget {
  const GeminiKeyDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const GeminiKeyDialog(),
  );

  @override
  State<GeminiKeyDialog> createState() => _GeminiKeyDialogState();
}

class _GeminiKeyDialogState extends State<GeminiKeyDialog> {
  final _key = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repository = AppScope.of(context).repository;
    final configured = repository.geminiConfigured;
    return AlertDialog(
      title: const Text('Gemini API key'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              configured
                  ? 'Gemini is active (${repository.pipeline.gemini.model}).'
                  : 'Gemini is not configured. Leads are filtered by keyword only.',
            ),
            const SizedBox(height: 8),
            const Text(
              'Use your own free Gemini API key from Google AI Studio '
              '(aistudio.google.com). It is stored only on this device.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _key,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: repository.hasUserGeminiKey
                    ? 'Replace saved key'
                    : 'Gemini API key',
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (repository.hasUserGeminiKey)
          TextButton(
            onPressed: () async {
              final navigator = Navigator.of(context);
              await repository.setGeminiApiKey(null);
              navigator.pop();
            },
            child: const Text('Remove key'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            final navigator = Navigator.of(context);
            if (_key.text.trim().isNotEmpty) {
              await repository.setGeminiApiKey(_key.text);
            }
            navigator.pop();
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
