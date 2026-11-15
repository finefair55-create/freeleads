import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Drives one highlight that sweeps diagonally across every [ShimmerBones]
/// below it, so a grid of placeholder cards shimmers as one surface rather
/// than each card on its own beat.
///
/// With reduced motion on, the bones stay still.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});

  final Widget child;

  static _ShimmerState? _of(BuildContext context) =>
      context.findAncestorStateOfType<_ShimmerState>();

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  Listenable get sweep => _controller;

  bool get still => !_controller.isAnimating;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduced) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The highlight, laid out over the whole shimmer area.
  LinearGradient gradient(Color base, Color highlight) => LinearGradient(
    begin: const Alignment(-1, -0.3),
    end: const Alignment(1, 0.3),
    colors: [base, highlight, base],
    stops: const [0.35, 0.5, 0.65],
    transform: _Sweep(_controller.value),
  );

  /// Where [box] sits inside the shimmer area, or null before layout.
  Rect? areaFor(RenderBox box) {
    final area = context.findRenderObject();
    if (area is! RenderBox || !area.hasSize || !box.attached) {
      return null;
    }
    final origin = box.localToGlobal(Offset.zero, ancestor: area);
    return (-origin) & area.size;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Sweep extends GradientTransform {
  const _Sweep(this.progress);

  final double progress;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * (progress * 2.4 - 1.2), 0, 0);
}

/// Paints [child]'s [SkeletonBox]es with the nearest [Shimmer]'s sweep.
/// Keep card chrome (borders, fills) outside, so only the bones glint.
class ShimmerBones extends StatelessWidget {
  const ShimmerBones({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shimmer = Shimmer._of(context);
    if (shimmer == null) {
      return child;
    }
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.surfaceContainerHighest;
    final highlight = Color.lerp(base, scheme.surface, 0.75)!;
    return ListenableBuilder(
      listenable: shimmer.sweep,
      builder: (context, child) {
        if (shimmer.still) {
          return child!;
        }
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            final box = context.findRenderObject();
            final area = box is RenderBox ? shimmer.areaFor(box) : null;
            return shimmer
                .gradient(base, highlight)
                .createShader(area ?? bounds);
          },
          child: child,
        );
      },
      child: child,
    );
  }
}

/// A rounded placeholder block for text or media that's still loading.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 14,
    this.radius = 6,
    this.widthFactor,
  });

  final double? width;

  /// Null fills the available height.
  final double? height;
  final double radius;

  /// Width as a share of the available width, for ragged text lines.
  final double? widthFactor;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
    if (widthFactor == null) {
      return box;
    }
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: box,
    );
  }
}

/// Placeholder in the shape of a [LeadCard]: badge row and budget, a
/// two-line title, a description and the source footer.
class LeadCardSkeleton extends StatelessWidget {
  const LeadCardSkeleton({super.key, this.height});

  final double? height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: ShimmerBones(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    SkeletonBox(width: 76, height: 20, radius: 999),
                    SizedBox(width: Spacing.xs),
                    SkeletonBox(width: 64, height: 20),
                    Spacer(),
                    SkeletonBox(width: 56, height: 20),
                  ],
                ),
                const SizedBox(height: Spacing.md),
                const SkeletonBox(height: 16, widthFactor: 0.9),
                const SizedBox(height: Spacing.xs),
                const SkeletonBox(height: 16, widthFactor: 0.55),
                const SizedBox(height: Spacing.sm),
                const SkeletonBox(height: 12, widthFactor: 0.95),
                const SizedBox(height: 6),
                const SkeletonBox(height: 12, widthFactor: 0.7),
                if (height != null)
                  const Spacer()
                else
                  const SizedBox(height: Spacing.md),
                const Row(
                  children: [
                    SkeletonBox(width: 72, height: 16),
                    SizedBox(width: Spacing.sm),
                    SkeletonBox(width: 110, height: 12),
                    Spacer(),
                    SkeletonBox(width: 36, height: 12),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
