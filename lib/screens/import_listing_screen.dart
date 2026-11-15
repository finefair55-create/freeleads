import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/lead.dart';
import '../services/gemini_service.dart';
import '../theme/app_theme.dart';
import '../widgets/lead_card.dart';

/// Turns pasted text (a job from a text message, email or another site)
/// into a lead with Gemini, or the on-device parser when Gemini isn't set
/// up or reachable.
class ImportListingScreen extends StatefulWidget {
  const ImportListingScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const ImportListingScreen()));

  @override
  State<ImportListingScreen> createState() => _ImportListingScreenState();
}

class _ImportListingScreenState extends State<ImportListingScreen> {
  final _controller = TextEditingController();
  Lead? _lead;
  bool _busy = false;
  bool _saving = false;
  String? _note;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      return;
    }
    FocusScope.of(context).unfocus();
    final gemini = AppScope.of(context).gemini;
    setState(() {
      _busy = true;
      _note = null;
      _lead = null;
    });
    GeminiException? fallback;
    try {
      final lead = await gemini.structureListing(
        raw,
        onFallback: (error) => fallback = error,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _lead = lead;
        _note = lead == null
            ? "This doesn't look like a real job request (spam or an ad), "
                  'so nothing was created.'
            : fallback != null
            ? '${fallback!.message} Read it on this device instead, so '
                  'check the details before saving.'
            : !gemini.isConfigured
            ? 'Read on this device. Add a Gemini key on the Profile tab '
                  'for cleaner results.'
            : null;
      });
    } catch (error) {
      debugPrint('Import failed: $error');
      if (mounted) {
        setState(
          () => _note = "Couldn't read this text. Try pasting more of it.",
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _save() async {
    final lead = _lead;
    if (lead == null || _saving) {
      return;
    }
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final repository = AppScope.of(context).repository;
    final zip = repository.profile.value?.zipCode ?? '';
    // A second tap would save twice and pop the screen underneath too.
    setState(() => _saving = true);
    try {
      await repository.saveParsedLead(
        lead.zipCode.isEmpty && zip.isNotEmpty
            ? lead.copyWith(zipCode: zip)
            : lead,
      );
    } catch (error) {
      debugPrint('Saving import failed: $error');
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't save this lead. Try again.")),
      );
      if (mounted) {
        setState(() => _saving = false);
      }
      return;
    }
    messenger.showSnackBar(
      const SnackBar(content: Text('Added to your leads.')),
    );
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Import listing')),
      body: LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: Spacing.page(constraints.maxWidth),
          children: [
            Text(
              'Paste a job from a text message, email or another website. '
              'FreeLeads pulls out the budget, location and contact details.',
              style: textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              minLines: 6,
              maxLines: 12,
              decoration: const InputDecoration(
                labelText: 'Listing text',
                hintText:
                    'e.g. "Need someone to fix a leaking faucet in '
                    'Brooklyn this week, \$100, text 555-0100"',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _busy ? null : _run,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),
                label: Text(_busy ? 'Reading…' : 'Create lead'),
              ),
            ),
            if (_note != null) ...[
              const SizedBox(height: 16),
              Text(_note!, style: textTheme.bodyMedium),
            ],
            if (_lead != null) ...[
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 480,
                  maxHeight: 240,
                ),
                child: LeadCard(lead: _lead!),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.add),
                  label: const Text('Add to my leads'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
