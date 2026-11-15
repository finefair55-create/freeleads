import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Shrinks [child] slightly while a finger or pointer is down on it, as
/// tactile feedback. Only listens to pointers, so taps still reach the
/// [InkWell]s and buttons inside.
///
/// With [raised], it also paints the theme's soft card shadow behind
/// [child] and lifts it a little while a mouse hovers (desktop).
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.scale = 0.98,
    this.raised = false,
    this.borderRadius = AppTheme.radiusLarge,
  });

  final Widget child;
  final double scale;
  final bool raised;

  /// Corner radius of the shadow; match the [child]'s shape.
  final double borderRadius;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;
  bool _hover = false;

  void _set(bool down) {
    // A pointer that went down here can lift after a scroll took this
    // off the list.
    if (mounted && _down != down) {
      setState(() => _down = down);
    }
  }

  void _setHover(bool hover) {
    if (mounted && _hover != hover) {
      setState(() => _hover = hover);
    }
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    var child = widget.child;
    if (widget.raised) {
      final shadows = AppShadows.of(context);
      final lifted = _hover && !_down && !still;
      child = MouseRegion(
        onEnter: (_) => _setHover(true),
        onExit: (_) => _setHover(false),
        child: AnimatedContainer(
          duration: still ? Duration.zero : AppTheme.motionFast,
          curve: Curves.easeOutCubic,
          transform: Matrix4.translationValues(0, lifted ? -2 : 0, 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            boxShadow: lifted ? shadows.hover : shadows.card,
          ),
          child: child,
        ),
      );
    }
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down && !still ? widget.scale : 1,
        duration: Duration(milliseconds: _down ? 90 : 160),
        curve: Curves.easeOutCubic,
        child: child,
      ),
    );
  }
}

/// Fades the current tab in with a slight rise whenever [index] changes,
/// the incoming half of Material's fade-through. Wrap an [IndexedStack]:
/// it only paints the active tab, so only that one animates, and tabs keep
/// their state.
class TabFadeThrough extends StatefulWidget {
  const TabFadeThrough({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<TabFadeThrough> createState() => _TabFadeThroughState();
}

class _TabFadeThroughState extends State<TabFadeThrough>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppTheme.motionMedium,
    value: 1,
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  late final Animation<Offset> _rise = Tween(
    begin: const Offset(0, 0.012),
    end: Offset.zero,
  ).animate(_fade);

  @override
  void didUpdateWidget(TabFadeThrough oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      if (still) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _rise, child: widget.child),
    );
  }
}

/// Fades and lifts [child] into place when it first appears, delayed by
/// its [index] so a list cascades in. The delay is capped, so long lists
/// don't keep the last items waiting.
///
/// Pass [animate] false for items the user has already seen (for example
/// a card scrolled back into view) so they appear at once.
class EntranceFade extends StatefulWidget {
  const EntranceFade({
    super.key,
    required this.index,
    required this.child,
    this.animate = true,
    this.onShown,
  });

  final int index;
  final Widget child;
  final bool animate;

  /// Called once the entrance has finished.
  final VoidCallback? onShown;

  static const _step = Duration(milliseconds: 45);
  static const _fade = Duration(milliseconds: 340);
  static const _maxStaggered = 8;

  @override
  State<EntranceFade> createState() => _EntranceFadeState();
}

class _EntranceFadeState extends State<EntranceFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _progress;

  @override
  void initState() {
    super.initState();
    final delay =
        EntranceFade._step * widget.index.clamp(0, EntranceFade._maxStaggered);
    final total = delay + EntranceFade._fade;
    _controller = AnimationController(vsync: this, duration: total);
    _progress = CurvedAnimation(
      parent: _controller,
      curve: Interval(
        delay.inMicroseconds / total.inMicroseconds,
        1,
        curve: Curves.easeOutCubic,
      ),
    );
    if (widget.animate) {
      _controller.forward().whenCompleteOrCancel(() => widget.onShown?.call());
    } else {
      _controller.value = 1;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _progress,
      child: AnimatedBuilder(
        animation: _progress,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, 14 * (1 - _progress.value)),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}
