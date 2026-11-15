import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/lead.dart';
import '../services/firestore_service.dart';
import '../services/lead_repository.dart';
import '../theme/app_theme.dart';

/// A customer posts a job directly: title, category, description, ZIP,
/// budget and contact info. With Firebase, posts reach other pros, so a
/// signed-out guest sees a sign-in gate instead of the form (anti-spam);
/// without Firebase, the lead stays on this device and needs no account.
class PostLeadScreen extends StatefulWidget {
  const PostLeadScreen({super.key});

  @override
  State<PostLeadScreen> createState() => _PostLeadScreenState();
}

class _PostLeadScreenState extends State<PostLeadScreen> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _zip = TextEditingController();
  final _budget = TextEditingController();
  final _contact = TextEditingController();
  String? _category;
  Stream<PosterAccount?>? _accountChanges;
  bool _saving = false;
  bool _signingIn = false;

  List<TextEditingController> get _controllers => [
    _title,
    _description,
    _zip,
    _budget,
    _contact,
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AppScope.of(context);
    if (_zip.text.isEmpty) {
      _zip.text = scope.repository.profile.value?.zipCode ?? '';
    }
    // One subscription for the screen's life, not one per rebuild.
    _accountChanges ??= scope.firestore.watchAccount();
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Signs in with Google and returns whether an account is now signed in.
  Future<bool> _signIn() async {
    final firestore = AppScope.of(context).firestore;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _signingIn = true);
    try {
      return await firestore.signInWithGoogle() != null;
    } catch (error) {
      final code = error is FirebaseAuthException ? error.code : null;
      messenger.showSnackBar(
        SnackBar(
          content: Text(switch (code) {
            'network-request-failed' =>
              'You need a connection to sign in. Try again when online.',
            'operation-not-allowed' ||
            'invalid-cert-hash' ||
            'app-not-authorized' ||
            'unsupported-platform' =>
              'Google sign-in is not set up for this app yet.',
            _ => 'Could not sign in with Google. Try again.',
          }),
        ),
      );
      return false;
    } finally {
      if (mounted) {
        setState(() => _signingIn = false);
      }
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    FocusScope.of(context).unfocus();
    final scope = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      final budget = _budget.text.trim();
      final outcome = await scope.repository.postLead(
        Lead(
          id: '',
          title: _title.text.trim(),
          description: _description.text.trim(),
          category: _category ?? '',
          location: '',
          zipCode: _zip.text.trim(),
          budget: budget.isEmpty ? null : budget,
          price: Lead.parsePrice(budget),
          contactInfo: _contact.text.trim(),
          createdAt: DateTime.now(),
        ),
      );
      if (!mounted) {
        return;
      }
      _formKey.currentState!.reset();
      final zip = _zip.text;
      for (final controller in _controllers) {
        controller.clear();
      }
      _zip.text = zip;
      setState(() => _category = null);
      messenger.showSnackBar(
        SnackBar(
          content: Text(switch (outcome) {
            PostOutcome.shared =>
              'Lead posted. Pros near ${_zipLabel(zip)} can see it now.',
            PostOutcome.queued =>
              "You're offline. The lead is saved and will be shared "
                  'automatically when you reconnect.',
            PostOutcome.deviceOnly =>
              'Saved on this device. Sharing with pros needs Firebase.',
          }),
        ),
      );
    } catch (error) {
      debugPrint('Post lead failed: $error');
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error is SignInRequiredException
                ? 'Sign in with Google to post a lead.'
                : 'Could not post this lead. Check your connection and try '
                      'again.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  String _zipLabel(String zip) => zip.isEmpty ? 'you' : zip;

  @override
  Widget build(BuildContext context) {
    final firestore = AppScope.of(context).firestore;
    final live = firestore.isAvailable;
    return StreamBuilder<PosterAccount?>(
      stream: _accountChanges,
      initialData: firestore.account,
      builder: (context, snapshot) {
        final account = snapshot.data;
        final busy = _saving || _signingIn;
        if (live && account == null) {
          // The fields live in this state, so anything typed before a
          // sign-out is still there after signing back in.
          return LayoutBuilder(
            builder: (context, constraints) => ListView(
              padding: Spacing.page(constraints.maxWidth),
              children: [
                _SignInGate(busy: _signingIn, onSignIn: busy ? null : _signIn),
              ],
            ),
          );
        }
        return Form(
          key: _formKey,
          child: LayoutBuilder(
            builder: (context, constraints) => ListView(
              padding: Spacing.page(constraints.maxWidth),
              children: [
                Text(
                  'Post a lead',
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  live
                      ? 'Need work done? Pros in your ZIP area see your post '
                            'in their feed right away, marked Direct Customer.'
                      : 'Firebase is not available on this device, so the lead '
                            'is saved locally and only you will see it.',
                ),
                if (account != null) ...[
                  const SizedBox(height: 16),
                  _AccountRow(
                    account: account,
                    onSignOut: busy ? null : firestore.signOut,
                  ),
                ],
                const SizedBox(height: 16),
                TextFormField(
                  controller: _title,
                  textInputAction: TextInputAction.next,
                  maxLength: 120,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    hintText: 'e.g. Fix leaking kitchen faucet',
                    counterText: '',
                  ),
                  validator: _required,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  // Fills the field, so a long category truncates instead
                  // of overflowing on narrow phones.
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [
                    for (final category in Lead.categories)
                      DropdownMenuItem(
                        value: category,
                        child: Text(category, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (value) => setState(() => _category = value),
                  validator: (value) => value == null ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _description,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    hintText: 'Scope, timing, anything a pro should know',
                  ),
                  maxLines: 3,
                  validator: _required,
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _zip,
                        textInputAction: TextInputAction.next,
                        keyboardType: TextInputType.number,
                        maxLength: 5,
                        decoration: const InputDecoration(
                          labelText: 'ZIP code',
                          counterText: '',
                        ),
                        validator: (value) =>
                            RegExp(r'^\d{5}$').hasMatch(value?.trim() ?? '')
                            ? null
                            : '5 digits',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _budget,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Budget (optional)',
                          hintText: r'$300 or $40/hr',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _contact,
                  textInputAction: TextInputAction.send,
                  onFieldSubmitted: (_) => busy ? null : _submit(),
                  decoration: const InputDecoration(
                    labelText: 'Contact info',
                    hintText: 'Phone or email for pros to reach you',
                  ),
                  validator: _required,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: busy ? null : _submit,
                  icon: const Icon(Icons.send_rounded),
                  label: Text(_saving ? 'Posting…' : 'Post lead'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String? _required(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Required';
    }
    return null;
  }
}

/// Shown to signed-out guests in place of the form: why posting needs an
/// account, and the one-tap Google sign-in that creates one.
class _SignInGate extends StatelessWidget {
  const _SignInGate({required this.busy, required this.onSignIn});

  final bool busy;
  final VoidCallback? onSignIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(AppTheme.radiusChip),
              ),
              child: Icon(
                Icons.verified_user_outlined,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: Spacing.md),
            Text(
              'Sign in to post a job',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              'Pros near you see posted jobs in their feed right away. To '
              'keep that feed free of spam, posting needs a free account.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              'Sign in or register with Google in one tap. No password '
              'needed, and pros only see the contact info you add to a post.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Spacing.lg),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onSignIn,
                icon: busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : const Icon(Icons.login),
                label: Text(
                  busy ? 'Signing in…' : 'Sign in or register with Google',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Posting as …" with a sign-out link.
class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.account, required this.onSignOut});

  final PosterAccount account;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.account_circle, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Posting as ${account.label}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: onSignOut, child: const Text('Sign out')),
        ],
      ),
    );
  }
}
