import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import '../models/lead_trust.dart';

/// 4pt spacing scale for padding and gaps.
abstract final class Spacing {
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 20.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const xxxl = 48.0;

  /// Insets for a single-column page: [md] on phones, like the feed's
  /// gutter, and on wide windows enough to keep the column at [maxWidth],
  /// centered, so forms and text don't stretch across a desktop monitor.
  static EdgeInsets page(double width, {double maxWidth = 720}) =>
      EdgeInsets.symmetric(
        horizontal: math.max(md, (width - maxWidth) / 2),
        vertical: md,
      );
}

class AppTheme {
  static const seed = Color(0xFF0F766E);

  /// Warm paper rather than pure white or gray, so white cards lift off it.
  static const canvas = Color(0xFFF6F5F1);
  static const ink = Color(0xFF14181F);
  static const darkCanvas = Color(0xFF0E1214);

  /// Corner radii used across cards, inputs and buttons.
  static const radiusLarge = 16.0;
  static const radiusMedium = 14.0;
  static const radiusSmall = 10.0;

  /// Top corners of bottom sheets.
  static const radiusSheet = 24.0;

  /// Chips, tabs and filter pills.
  static const radiusChip = 12.0;

  /// Fully rounded ends for pills and badges.
  static const radiusPill = 999.0;

  /// Shared motion timings, so every transition in the app feels related.
  static const motionFast = Duration(milliseconds: 160);
  static const motionMedium = Duration(milliseconds: 260);
  static const motionSlow = Duration(milliseconds: 380);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    ).copyWith(surface: dark ? darkCanvas : null);
    final background = dark ? darkCanvas : canvas;
    final foreground = dark ? scheme.onSurface : ink;
    final raised = dark ? scheme.surfaceContainerLow : Colors.white;
    final hairline = scheme.outlineVariant.withValues(alpha: dark ? 0.5 : 0.6);
    final text = _textTheme(
      ThemeData(brightness: brightness).textTheme,
      foreground,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      textTheme: text,
      extensions: [
        dark ? TrustColors.dark : TrustColors.light,
        dark ? SourceColors.dark : SourceColors.light,
        dark ? AppShadows.dark : AppShadows.light,
      ],
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          // Desktop gets the same fade-forward motion as Android instead of
          // the default zoom.
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: foreground,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.6,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: raised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
          side: BorderSide(color: hairline),
        ),
      ),
      dividerTheme: DividerThemeData(color: hairline, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: raised,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          borderSide: BorderSide(color: hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          borderSide: BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMedium),
          ),
          textStyle: text.labelLarge?.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.1,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 44),
          side: BorderSide(color: hairline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMedium),
          ),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall),
          ),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: raised,
        selectedColor: scheme.primaryContainer,
        side: BorderSide(color: hairline),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusChip),
        ),
        labelStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          side: BorderSide(color: hairline),
          selectedBackgroundColor: scheme.primaryContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMedium),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: raised,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => text.labelMedium?.copyWith(
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: raised,
        indicatorColor: scheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: scheme.primary),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: text.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: raised,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: scheme.outlineVariant,
        // Rounded top only: sheets rise from the bottom edge.
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(radiusSheet),
          ),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      listTileTheme: const ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusSmall)),
        ),
      ),
    );
  }

  /// Tighter headings and slightly roomier body text than the Material
  /// defaults, closer to an editorial layout.
  static TextTheme _textTheme(TextTheme base, Color ink) {
    final themed = base.apply(bodyColor: ink, displayColor: ink);
    TextStyle? heading(TextStyle? style, double spacing) => style?.copyWith(
      fontWeight: FontWeight.w800,
      letterSpacing: spacing,
      height: 1.15,
    );
    return themed.copyWith(
      headlineLarge: heading(themed.headlineLarge, -1),
      headlineMedium: heading(themed.headlineMedium, -0.8),
      headlineSmall: heading(themed.headlineSmall, -0.6),
      titleLarge: themed.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
      ),
      titleMedium: themed.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        height: 1.3,
      ),
      bodyLarge: themed.bodyLarge?.copyWith(height: 1.45),
      bodyMedium: themed.bodyMedium?.copyWith(height: 1.4),
      labelSmall: themed.labelSmall?.copyWith(letterSpacing: 0.2),
    );
  }
}

/// Soft, layered shadows for raised surfaces, tuned per brightness. Light
/// mode uses ink-tinted shadows; dark mode leans on deeper, wider ones,
/// since a faint shadow vanishes on a dark canvas.
@immutable
class AppShadows extends ThemeExtension<AppShadows> {
  const AppShadows({
    required this.card,
    required this.hover,
    required this.floating,
  });

  static const light = AppShadows(
    card: [
      BoxShadow(color: Color(0x0814181F), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x0D14181F), blurRadius: 14, offset: Offset(0, 4)),
    ],
    hover: [
      BoxShadow(color: Color(0x0D14181F), blurRadius: 4, offset: Offset(0, 2)),
      BoxShadow(
        color: Color(0x1A14181F),
        blurRadius: 24,
        offset: Offset(0, 10),
      ),
    ],
    floating: [
      BoxShadow(color: Color(0x1214181F), blurRadius: 4, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x1C14181F), blurRadius: 20, offset: Offset(0, 6)),
    ],
  );

  static const dark = AppShadows(
    card: [
      BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 3)),
    ],
    hover: [
      BoxShadow(color: Color(0x52000000), blurRadius: 22, offset: Offset(0, 8)),
    ],
    floating: [
      BoxShadow(color: Color(0x59000000), blurRadius: 20, offset: Offset(0, 6)),
    ],
  );

  /// Resting cards in the feed.
  final List<BoxShadow> card;

  /// Cards under a mouse pointer (desktop).
  final List<BoxShadow> hover;

  /// Overlays above other content: map callouts, legends, banners.
  final List<BoxShadow> floating;

  static AppShadows of(BuildContext context) =>
      Theme.of(context).extension<AppShadows>() ?? light;

  @override
  AppShadows copyWith({
    List<BoxShadow>? card,
    List<BoxShadow>? hover,
    List<BoxShadow>? floating,
  }) {
    return AppShadows(
      card: card ?? this.card,
      hover: hover ?? this.hover,
      floating: floating ?? this.floating,
    );
  }

  @override
  AppShadows lerp(AppShadows? other, double t) {
    if (other == null) {
      return this;
    }
    return AppShadows(
      card: BoxShadow.lerpList(card, other.card, t)!,
      hover: BoxShadow.lerpList(hover, other.hover, t)!,
      floating: BoxShadow.lerpList(floating, other.floating, t)!,
    );
  }
}

/// Badge colors that tell listing sources apart at a glance, tuned per
/// brightness. The badge always shows the source name too.
@immutable
class SourceColors extends ThemeExtension<SourceColors> {
  const SourceColors({
    required this.craigslist,
    required this.direct,
    required this.imported,
    required this.other,
  });

  static const light = SourceColors(
    craigslist: (Color(0xFFF1EAFB), Color(0xFF5B21B6)),
    // Solid fill, unlike the tinted site badges, so posts made directly by
    // customers stand out in the feed.
    direct: (Color(0xFF0F766E), Color(0xFFFFFFFF)),
    imported: (Color(0xFFF1F0EC), Color(0xFF44403C)),
    other: (Color(0xFFF1F0EC), Color(0xFF44403C)),
  );

  static const dark = SourceColors(
    craigslist: (Color(0xFF2E1B4E), Color(0xFFDDD0FA)),
    direct: (Color(0xFF5EEAD4), Color(0xFF042F2E)),
    imported: (Color(0xFF2A2826), Color(0xFFE2DFDA)),
    other: (Color(0xFF2A2826), Color(0xFFE2DFDA)),
  );

  /// (background, foreground) pairs.
  final (Color, Color) craigslist;
  final (Color, Color) direct;
  final (Color, Color) imported;
  final (Color, Color) other;

  static SourceColors of(BuildContext context) =>
      Theme.of(context).extension<SourceColors>() ?? light;

  @override
  SourceColors copyWith({
    (Color, Color)? craigslist,
    (Color, Color)? direct,
    (Color, Color)? imported,
    (Color, Color)? other,
  }) {
    return SourceColors(
      craigslist: craigslist ?? this.craigslist,
      direct: direct ?? this.direct,
      imported: imported ?? this.imported,
      other: other ?? this.other,
    );
  }

  @override
  SourceColors lerp(SourceColors? other, double t) {
    if (other == null) {
      return this;
    }
    (Color, Color) mix((Color, Color) a, (Color, Color) b) =>
        (Color.lerp(a.$1, b.$1, t)!, Color.lerp(a.$2, b.$2, t)!);
    return SourceColors(
      craigslist: mix(craigslist, other.craigslist),
      direct: mix(direct, other.direct),
      imported: mix(imported, other.imported),
      other: mix(this.other, other.other),
    );
  }
}

/// Badge colors for trust tiers: green, amber and red, tuned per
/// brightness so the label keeps at least 4.5:1 contrast.
@immutable
class TrustColors extends ThemeExtension<TrustColors> {
  const TrustColors({
    required this.reliable,
    required this.onReliable,
    required this.questionable,
    required this.onQuestionable,
    required this.spam,
    required this.onSpam,
  });

  static const light = TrustColors(
    reliable: Color(0xFFDCFCE7),
    onReliable: Color(0xFF166534),
    questionable: Color(0xFFFEF3C7),
    onQuestionable: Color(0xFF92400E),
    spam: Color(0xFFFEE2E2),
    onSpam: Color(0xFF991B1B),
  );

  static const dark = TrustColors(
    reliable: Color(0xFF14532D),
    onReliable: Color(0xFFBBF7D0),
    questionable: Color(0xFF713F12),
    onQuestionable: Color(0xFFFDE68A),
    spam: Color(0xFF7F1D1D),
    onSpam: Color(0xFFFECACA),
  );

  final Color reliable;
  final Color onReliable;
  final Color questionable;
  final Color onQuestionable;
  final Color spam;
  final Color onSpam;

  static TrustColors of(BuildContext context) =>
      Theme.of(context).extension<TrustColors>() ?? light;

  /// (background, foreground) for [trust].
  (Color, Color) colorsFor(LeadTrust trust) => switch (trust) {
    LeadTrust.reliable => (reliable, onReliable),
    LeadTrust.questionable => (questionable, onQuestionable),
    LeadTrust.spam => (spam, onSpam),
  };

  @override
  TrustColors copyWith({
    Color? reliable,
    Color? onReliable,
    Color? questionable,
    Color? onQuestionable,
    Color? spam,
    Color? onSpam,
  }) {
    return TrustColors(
      reliable: reliable ?? this.reliable,
      onReliable: onReliable ?? this.onReliable,
      questionable: questionable ?? this.questionable,
      onQuestionable: onQuestionable ?? this.onQuestionable,
      spam: spam ?? this.spam,
      onSpam: onSpam ?? this.onSpam,
    );
  }

  @override
  TrustColors lerp(TrustColors? other, double t) {
    if (other == null) {
      return this;
    }
    return TrustColors(
      reliable: Color.lerp(reliable, other.reliable, t)!,
      onReliable: Color.lerp(onReliable, other.onReliable, t)!,
      questionable: Color.lerp(questionable, other.questionable, t)!,
      onQuestionable: Color.lerp(onQuestionable, other.onQuestionable, t)!,
      spam: Color.lerp(spam, other.spam, t)!,
      onSpam: Color.lerp(onSpam, other.onSpam, t)!,
    );
  }
}
