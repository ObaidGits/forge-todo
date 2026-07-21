import 'package:flutter/material.dart';

/// Reduced-motion helpers shared across every feature (ux-design §10,
/// `NFR-A11Y-001`).
///
/// When the platform reduce-motion setting is on (surfaced by Flutter as
/// [MediaQueryData.disableAnimations]) Forge removes non-essential transitions
/// and replaces progress animation with immediate state. Widgets route their
/// motion decisions through these helpers so the behavior is consistent and
/// testable rather than re-derived per screen.
abstract final class ForgeMotion {
  /// Whether non-essential animation should be suppressed for [context].
  static bool reduceMotion(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  /// Collapses [duration] to [Duration.zero] when reduce-motion is active so a
  /// transition resolves to its end state immediately.
  static Duration duration(BuildContext context, Duration duration) =>
      reduceMotion(context) ? Duration.zero : duration;
}

/// A drop-in [AnimatedSwitcher] that honors the platform reduce-motion setting.
///
/// With reduce motion on, the [child] is shown immediately with no cross-fade;
/// otherwise it animates over [duration]. Callers get consistent, accessible
/// behavior without repeating the branch (ux-design §10).
final class ForgeAnimatedSwitcher extends StatelessWidget {
  const ForgeAnimatedSwitcher({
    required this.child,
    this.duration = const Duration(milliseconds: 200),
    super.key,
  });

  final Widget child;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    if (ForgeMotion.reduceMotion(context)) {
      return child;
    }
    return AnimatedSwitcher(duration: duration, child: child);
  }
}
