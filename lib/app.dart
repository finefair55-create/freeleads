import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'models/search_profile.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/lead_repository.dart';
import 'theme/app_theme.dart';

class FreeLeadsApp extends StatelessWidget {
  const FreeLeadsApp({super.key, required this.repository});

  final LeadRepository repository;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      repository: repository,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: repository.themeMode,
        builder: (context, mode, _) => MaterialApp(
          title: 'FreeLeads',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: mode,
          home: _Root(repository: repository),
        ),
      ),
    );
  }
}

/// Onboarding until a valid profile is saved, then the home screen.
class _Root extends StatelessWidget {
  const _Root({required this.repository});

  final LeadRepository repository;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SearchProfile?>(
      valueListenable: repository.profile,
      builder: (context, profile, _) {
        final ready = profile != null && profile.isValid;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: ready
              ? const HomeScreen(key: ValueKey('home'))
              : const OnboardingScreen(key: ValueKey('onboarding')),
        );
      },
    );
  }
}
