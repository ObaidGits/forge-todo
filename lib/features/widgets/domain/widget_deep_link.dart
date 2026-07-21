/// Widget deep-link parsing and building (R-WIDGET-003).
///
/// A native home-screen widget cannot mutate data directly. Instead, a tap
/// packages an authenticated [WidgetIntent] into a `forge://widget/...` deep
/// link that opens the app; the Dart bridge then verifies it (signature,
/// profile binding, freshness) before any command runs.
///
/// This file is the pure, dependency-free contract for that URI, shared by:
///
///   * the native side, which BUILDS the URI (Android/iOS mirror
///     [WidgetDeepLink.buildActionUri]); and
///   * the app, which PARSES an inbound URI back into an untrusted
///     [WidgetIntent] via [WidgetDeepLink.parse].
///
/// Parsing is deliberately strict and unknown-safe: a wrong scheme/host,
/// missing field, unknown action/surface, or non-integer timestamp yields
/// `null` (the app then opens normally instead of trusting a malformed link).
/// A structurally valid link is still fully re-verified downstream, so parsing
/// leniency can never authorize a write.
library;

import 'package:forge/features/widgets/domain/widget_intent.dart';
import 'package:forge/features/widgets/domain/widget_platform_contract.dart';
import 'package:forge/features/widgets/domain/widget_surface.dart';

/// A parsed widget deep link: either an authenticated action carrying an
/// untrusted [WidgetIntent], or a plain request to open a [surface].
sealed class WidgetDeepLink {
  const WidgetDeepLink();

  /// Parses [uri] into a [WidgetDeepLink], or returns null if it is not a
  /// well-formed Forge widget link. Never throws.
  static WidgetDeepLink? parse(Uri uri) {
    if (uri.scheme != WidgetPlatformContract.deepLinkScheme ||
        uri.host != WidgetPlatformContract.deepLinkHost) {
      return null;
    }
    final List<String> segments = uri.pathSegments
        .where((String segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.length != 1) {
      return null;
    }
    return switch (segments.first) {
      WidgetPlatformContract.deepLinkActionPath => _parseAction(uri),
      WidgetPlatformContract.deepLinkOpenPath => _parseOpen(uri),
      _ => null,
    };
  }

  static WidgetDeepLink? _parseOpen(Uri uri) {
    final WidgetSurface? surface = WidgetSurface.fromWire(
      uri.queryParameters[WidgetPlatformContract.paramSurface],
    );
    if (surface == null) {
      return null;
    }
    return WidgetOpenDeepLink(surface);
  }

  static WidgetDeepLink? _parseAction(Uri uri) {
    final Map<String, String> params = uri.queryParameters;
    final WidgetIntentAction? action = WidgetIntentAction.fromWire(
      params[WidgetPlatformContract.paramAction],
    );
    // Validate the surface is a known one, but keep its stable wire form.
    final String? surfaceWire = params[WidgetPlatformContract.paramSurface];
    final WidgetSurface? surface = WidgetSurface.fromWire(surfaceWire);
    final String? intentId = params[WidgetPlatformContract.paramIntentId];
    final String? profileId = params[WidgetPlatformContract.paramProfileId];
    final String? target = params[WidgetPlatformContract.paramTarget];
    final String? token = params[WidgetPlatformContract.paramToken];
    final int? issuedAt = int.tryParse(
      params[WidgetPlatformContract.paramIssuedAt] ?? '',
    );

    if (action == null ||
        surface == null ||
        surfaceWire == null ||
        intentId == null ||
        intentId.isEmpty ||
        profileId == null ||
        target == null ||
        target.isEmpty ||
        token == null ||
        token.isEmpty ||
        issuedAt == null) {
      return null;
    }

    return WidgetActionDeepLink(
      WidgetIntent(
        intentId: intentId,
        profileId: profileId,
        action: action,
        surfaceWire: surfaceWire,
        targetEntityId: target,
        issuedAtUtcMicros: issuedAt,
        token: token,
      ),
    );
  }

  /// Builds the canonical action URI for [intent]. The native signer produces
  /// the same URI so a round trip through [parse] reconstructs [intent].
  static Uri buildActionUri(WidgetIntent intent) => Uri(
    scheme: WidgetPlatformContract.deepLinkScheme,
    host: WidgetPlatformContract.deepLinkHost,
    pathSegments: <String>[WidgetPlatformContract.deepLinkActionPath],
    queryParameters: <String, String>{
      WidgetPlatformContract.paramAction: intent.action.wireName,
      WidgetPlatformContract.paramIntentId: intent.intentId,
      WidgetPlatformContract.paramIssuedAt: '${intent.issuedAtUtcMicros}',
      WidgetPlatformContract.paramProfileId: intent.profileId,
      WidgetPlatformContract.paramSurface: intent.surfaceWire,
      WidgetPlatformContract.paramTarget: intent.targetEntityId,
      WidgetPlatformContract.paramToken: intent.token,
    },
  );

  /// Builds the "open this surface" URI for a non-mutating tap.
  static Uri buildOpenUri(WidgetSurface surface) => Uri(
    scheme: WidgetPlatformContract.deepLinkScheme,
    host: WidgetPlatformContract.deepLinkHost,
    pathSegments: <String>[WidgetPlatformContract.deepLinkOpenPath],
    queryParameters: <String, String>{
      WidgetPlatformContract.paramSurface: surface.wireName,
    },
  );
}

/// An authenticated widget action link carrying an untrusted [WidgetIntent].
final class WidgetActionDeepLink extends WidgetDeepLink {
  const WidgetActionDeepLink(this.intent);

  final WidgetIntent intent;
}

/// A plain request to open [surface] in the app (no mutation).
final class WidgetOpenDeepLink extends WidgetDeepLink {
  const WidgetOpenDeepLink(this.surface);

  final WidgetSurface surface;
}
