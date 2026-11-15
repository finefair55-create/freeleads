import 'dart:async';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/search_profile.dart';
import '../models/trade.dart';
import '../services/zip_geocoder.dart';
import '../theme/app_theme.dart';
import '../widgets/app_logo.dart';
import '../widgets/profile_pickers.dart';

/// First-launch setup: welcome, pick a trade, then home ZIP and radius.
/// Finishing saves the [SearchProfile] (on the device and, when Firebase is
/// available, as a private backup) and starts the first search; the app
/// then switches to the home screen on its own.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _steps = 3;

  final _pages = PageController();
  final _zip = TextEditingController();
  final _zipForm = GlobalKey<FormState>();
  int _step = 0;
  String _profession = '';
  int _radius = 25;
  bool _restored = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    ZipGeocoder.instance.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    }, onError: (Object error) => debugPrint('ZIP table: $error'));
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  @override
  void dispose() {
    _pages.dispose();
    _zip.dispose();
    super.dispose();
  }

  /// Prefills from a Firebase backup, if this sign-in has one.
  Future<void> _restore() async {
    if (!mounted) {
      return;
    }
    final saved = await AppScope.of(context).repository.remoteProfile();
    if (!mounted || saved == null || _profession.isNotEmpty) {
      return;
    }
    setState(() {
      _profession = saved.profession;
      _zip.text = saved.zipCode;
      _radius = SearchProfile.radiusOptions.contains(saved.radiusMiles)
          ? saved.radiusMiles
          : 25;
      _restored = true;
    });
  }

  void _go(int step) {
    FocusScope.of(context).unfocus();
    setState(() => _step = step);
    _pages.animateToPage(
      step,
      duration: AppTheme.motionMedium,
      curve: Curves.easeOutCubic,
    );
  }

  bool get _canContinue => switch (_step) {
    1 => _profession.trim().isNotEmpty,
    2 => validateHomeZip(_zip.text) == null && !_saving,
    _ => true,
  };

  void _next() {
    if (_step < _steps - 1) {
      _go(_step + 1);
      return;
    }
    if (!(_zipForm.currentState?.validate() ?? false)) {
      return;
    }
    setState(() => _saving = true);
    final repository = AppScope.of(context).repository;
    // The root swaps to the home screen as soon as the profile is saved;
    // the first search keeps running there.
    unawaited(
      repository
          .updateProfile(
            SearchProfile(
              profession: _profession.trim(),
              zipCode: _zip.text.trim(),
              radiusMiles: _radius,
            ),
          )
          .catchError((Object error) {
            debugPrint('Saving profile failed: $error');
            if (mounted) {
              setState(() => _saving = false);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("Couldn't save your profile. Try again."),
                ),
              );
            }
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.xs,
                    Spacing.xs,
                    Spacing.md,
                    0,
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 48,
                        child: _step == 0
                            ? null
                            : IconButton(
                                tooltip: 'Back',
                                onPressed: () => _go(_step - 1),
                                icon: const Icon(Icons.arrow_back),
                              ),
                      ),
                      Expanded(
                        child: Semantics(
                          label: 'Step ${_step + 1} of $_steps',
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(99),
                            child: TweenAnimationBuilder<double>(
                              tween: Tween(end: (_step + 1) / _steps),
                              duration: AppTheme.motionMedium,
                              builder: (context, value, _) =>
                                  LinearProgressIndicator(
                                    value: value,
                                    minHeight: 6,
                                    backgroundColor:
                                        scheme.surfaceContainerHighest,
                                  ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: PageView(
                    controller: _pages,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      const _WelcomeStep(),
                      _TradeStep(
                        profession: _profession,
                        restored: _restored,
                        onChanged: (value) =>
                            setState(() => _profession = value),
                      ),
                      _AreaStep(
                        profession: _profession,
                        formKey: _zipForm,
                        zip: _zip,
                        radius: _radius,
                        onZipChanged: () => setState(() {}),
                        onRadiusChanged: (miles) =>
                            setState(() => _radius = miles),
                        onSubmitted: _canContinue ? _next : null,
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.md,
                    Spacing.xs,
                    Spacing.md,
                    Spacing.md,
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      onPressed: _canContinue ? _next : null,
                      child: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(switch (_step) {
                              0 => 'Get started',
                              1 => 'Continue',
                              _ => 'Start finding leads',
                            }),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepScaffold extends StatelessWidget {
  const _StepScaffold({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        Spacing.md,
        28,
        Spacing.md,
        Spacing.md,
      ),
      children: [
        Text(
          title,
          style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: textTheme.bodyLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        child,
      ],
    );
  }
}

class _WelcomeStep extends StatelessWidget {
  const _WelcomeStep();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    Widget point(IconData icon, String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: scheme.primaryContainer,
            child: Icon(icon, color: scheme.onPrimaryContainer, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        Spacing.md,
        36,
        Spacing.md,
        Spacing.md,
      ),
      children: [
        const Align(
          alignment: AlignmentDirectional.centerStart,
          child: AppLogo(size: 56),
        ),
        const SizedBox(height: 16),
        Text(
          'Find local jobs, free',
          style: textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'FreeLeads finds people near you who need your kind of work. '
          'No lead fees, no bidding.',
          style: textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 32),
        point(
          Icons.travel_explore,
          'Searches from your phone',
          'Listing sites are searched directly from this device, at a '
              'gentle pace that keeps your connection in good standing.',
        ),
        point(
          Icons.verified_outlined,
          'Every lead is graded',
          'Reliable, Questionable or Possible spam, so you know what to '
              'answer first and what to skip.',
        ),
        point(
          Icons.people_alt_outlined,
          'Customers post here too',
          'Leads customers post in FreeLeads show up for pros in the same area.',
        ),
      ],
    );
  }
}

class _TradeStep extends StatelessWidget {
  const _TradeStep({
    required this.profession,
    required this.restored,
    required this.onChanged,
  });

  final String profession;
  final bool restored;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return _StepScaffold(
      title: 'What work do you do?',
      subtitle: restored
          ? 'Welcome back. We restored your saved choices; change anything '
                'you like.'
          : 'Pick your trade. You can change it any time on the Profile tab.',
      child: TradePicker(value: profession, onChanged: onChanged),
    );
  }
}

class _AreaStep extends StatelessWidget {
  const _AreaStep({
    required this.profession,
    required this.formKey,
    required this.zip,
    required this.radius,
    required this.onZipChanged,
    required this.onRadiusChanged,
    required this.onSubmitted,
  });

  final String profession;
  final GlobalKey<FormState> formKey;
  final TextEditingController zip;
  final int radius;
  final VoidCallback onZipChanged;
  final ValueChanged<int> onRadiusChanged;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return _StepScaffold(
      title: 'Where do you work?',
      subtitle:
          'Leads are searched around your home ZIP. Only the ZIP is used, '
          'never your exact location.',
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: zip,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              maxLength: 5,
              autofillHints: const [AutofillHints.postalCode],
              decoration: InputDecoration(
                labelText: 'Home ZIP',
                prefixIcon: const Icon(Icons.place_outlined),
                counterText: '',
                helperText: unknownZipNote(zip.text),
                helperMaxLines: 2,
              ),
              onChanged: (_) => onZipChanged(),
              onFieldSubmitted: (_) => onSubmitted?.call(),
              validator: validateHomeZip,
            ),
            const SizedBox(height: 24),
            Text('How far will you travel?', style: textTheme.titleSmall),
            const SizedBox(height: 10),
            RadiusPicker(value: radius, onChanged: onRadiusChanged),
            const SizedBox(height: 24),
            Text(
              'Searching for ${Trade.displayName(profession)} jobs.',
              style: textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
