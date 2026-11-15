import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The FreeLeads mark: a bold "F" in a rounded teal square. Always the
/// brand teal, in light and dark themes alike, so it reads as a logo
/// rather than a themed control. Decorative; pair it with the name.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // A soft top-to-bottom lift keeps the flat square from looking
          // like a placeholder.
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(AppTheme.seed, Colors.white, 0.12)!,
              AppTheme.seed,
            ],
          ),
          borderRadius: BorderRadius.circular(size * 0.28),
        ),
        child: Text(
          'F',
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.62,
            height: 1,
            fontWeight: FontWeight.w800,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}
