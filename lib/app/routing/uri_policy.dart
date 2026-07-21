import 'dart:convert';

/// A privacy-preserving result that never repeats rejected URI input.
enum UriRejection {
  malformed,
  tooLong,
  unsupportedScheme,
  untrustedHost,
  disallowedRoute,
  invalidIdentifier,
  nonCanonical,
  duplicateParameter,
  unexpectedParameter,
  explicitActionRequired,
  unsupportedArgument,
}

final class UriPolicyDecision {
  const UriPolicyDecision._({
    required this.allowed,
    this.canonicalUri,
    this.routeLocation,
    this.rejection,
    this.requiresExplicitAction = false,
  });

  factory UriPolicyDecision.allow({
    required Uri canonicalUri,
    String? routeLocation,
    bool requiresExplicitAction = false,
  }) => UriPolicyDecision._(
    allowed: true,
    canonicalUri: canonicalUri,
    routeLocation: routeLocation,
    requiresExplicitAction: requiresExplicitAction,
  );

  factory UriPolicyDecision.reject(UriRejection rejection) =>
      UriPolicyDecision._(allowed: false, rejection: rejection);

  final bool allowed;
  final Uri? canonicalUri;
  final String? routeLocation;
  final UriRejection? rejection;
  final bool requiresExplicitAction;
}

/// The sole policy boundary for inbound links, outbound links, and desktop
/// protocol arguments. It intentionally defaults to denying every external
/// host; features must opt reviewed hosts in at composition time.
final class UriPolicy {
  UriPolicy({
    this.maximumTotalBytes = 2048,
    this.maximumComponentBytes = 256,
    Set<String> inboundSchemes = const <String>{'forge'},
    Set<String> inboundHosts = const <String>{'app'},
    Set<String> externalHosts = const <String>{},
  }) : inboundSchemes = Set<String>.unmodifiable(inboundSchemes),
       inboundHosts = Set<String>.unmodifiable(inboundHosts),
       externalHosts = Set<String>.unmodifiable(externalHosts);

  final int maximumTotalBytes;
  final int maximumComponentBytes;
  final Set<String> inboundSchemes;
  final Set<String> inboundHosts;
  final Set<String> externalHosts;

  UriPolicyDecision evaluateInbound(String raw) {
    final UriPolicyDecision? structural = _parse(raw);
    if (structural != null) {
      return structural;
    }
    final Uri uri = Uri.parse(raw);
    if (!inboundSchemes.contains(uri.scheme)) {
      return UriPolicyDecision.reject(UriRejection.unsupportedScheme);
    }
    if (!inboundHosts.contains(uri.host)) {
      return UriPolicyDecision.reject(UriRejection.untrustedHost);
    }
    if (uri.hasPort || uri.userInfo.isNotEmpty || uri.fragment.isNotEmpty) {
      return UriPolicyDecision.reject(UriRejection.nonCanonical);
    }
    final UriRejection? queryRejection = _validateEmptyQuery(uri);
    if (queryRejection != null) {
      return UriPolicyDecision.reject(queryRejection);
    }
    final UriRejection? routeRejection = validateRouteLocation(uri.path);
    if (routeRejection != null) {
      return UriPolicyDecision.reject(routeRejection);
    }
    return UriPolicyDecision.allow(canonicalUri: uri, routeLocation: uri.path);
  }

  UriPolicyDecision evaluateOutbound(Uri uri, {required bool userInitiated}) {
    final String raw = uri.toString();
    final UriPolicyDecision? structural = _parse(raw);
    if (structural != null) {
      return structural;
    }
    if (uri.scheme != 'https') {
      return UriPolicyDecision.reject(UriRejection.unsupportedScheme);
    }
    if (!externalHosts.contains(uri.host)) {
      return UriPolicyDecision.reject(UriRejection.untrustedHost);
    }
    if (uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      return UriPolicyDecision.reject(UriRejection.unexpectedParameter);
    }
    if (!userInitiated) {
      return UriPolicyDecision.reject(UriRejection.explicitActionRequired);
    }
    return UriPolicyDecision.allow(
      canonicalUri: uri,
      requiresExplicitAction: true,
    );
  }

  UriPolicyDecision evaluateDesktopArguments(List<String> arguments) {
    if (arguments.length != 1) {
      return UriPolicyDecision.reject(UriRejection.unsupportedArgument);
    }
    return evaluateInbound(arguments.single);
  }

  UriRejection? validateRouteLocation(String location) {
    if (!location.startsWith('/') || location.length > maximumTotalBytes) {
      return UriRejection.disallowedRoute;
    }
    final List<String> segments = Uri.parse(location).pathSegments;
    if (segments.any(
      (String segment) =>
          segment.isEmpty ||
          utf8.encode(segment).length > maximumComponentBytes ||
          !_safeSegment.hasMatch(segment),
    )) {
      return UriRejection.nonCanonical;
    }
    if (_staticRoutes.contains(location)) {
      return null;
    }
    if (_matchesIdRoute(segments)) {
      return null;
    }
    return segments.any(_looksLikeInvalidId)
        ? UriRejection.invalidIdentifier
        : UriRejection.disallowedRoute;
  }

  UriPolicyDecision? _parse(String raw) {
    if (raw.isEmpty || raw != raw.trim()) {
      return UriPolicyDecision.reject(UriRejection.nonCanonical);
    }
    if (utf8.encode(raw).length > maximumTotalBytes ||
        raw.codeUnits.any((int code) => code < 0x20 || code > 0x7E)) {
      return UriPolicyDecision.reject(UriRejection.tooLong);
    }
    if (!_hasCanonicalPercentEncoding(raw)) {
      return UriPolicyDecision.reject(UriRejection.nonCanonical);
    }
    try {
      final Uri uri = Uri.parse(raw);
      if (!uri.hasScheme || uri.host.isEmpty) {
        return UriPolicyDecision.reject(UriRejection.malformed);
      }
      if (uri.scheme != uri.scheme.toLowerCase() ||
          uri.host != uri.host.toLowerCase() ||
          uri.toString() != raw) {
        return UriPolicyDecision.reject(UriRejection.nonCanonical);
      }
      for (final String segment in uri.pathSegments) {
        if (utf8.encode(segment).length > maximumComponentBytes) {
          return UriPolicyDecision.reject(UriRejection.tooLong);
        }
      }
      return null;
    } on FormatException {
      return UriPolicyDecision.reject(UriRejection.malformed);
    }
  }

  UriRejection? _validateEmptyQuery(Uri uri) {
    for (final MapEntry<String, List<String>> entry
        in uri.queryParametersAll.entries) {
      if (entry.value.length > 1) {
        return UriRejection.duplicateParameter;
      }
    }
    return uri.query.isEmpty ? null : UriRejection.unexpectedParameter;
  }

  static bool _matchesIdRoute(List<String> segments) {
    if (segments.length == 2) {
      return switch (segments.first) {
        'tasks' ||
        'goals' ||
        'learn' ||
        'habits' ||
        'notes' ||
        'planner' ||
        'focus' ||
        'fitness' => isOpaqueId(segments[1]),
        _ => false,
      };
    }
    if (segments.length == 3) {
      if (segments[0] == 'tasks' && segments[1] == 'filter') {
        return isOpaqueId(segments[2]);
      }
      if (segments[0] == 'goals' && segments[2] == 'roadmap') {
        return isOpaqueId(segments[1]);
      }
    }
    return segments.length == 4 &&
        segments[0] == 'learn' &&
        segments[2] == 'item' &&
        isOpaqueId(segments[1]) &&
        isOpaqueId(segments[3]);
  }

  static bool _looksLikeInvalidId(String segment) =>
      !_nonIdRouteSegments.contains(segment);

  static bool isOpaqueId(String value) => _uuidV7.hasMatch(value);

  static bool _hasCanonicalPercentEncoding(String raw) {
    for (int index = 0; index < raw.length; index += 1) {
      if (raw.codeUnitAt(index) != 0x25) {
        continue;
      }
      if (index + 2 >= raw.length) {
        return false;
      }
      final String pair = raw.substring(index + 1, index + 3);
      if (!_upperHex.hasMatch(pair)) {
        return false;
      }
      final int byte = int.parse(pair, radix: 16);
      if (_isUnreserved(byte) || byte == 0x2F || byte == 0x5C) {
        return false;
      }
      index += 2;
    }
    return true;
  }

  static bool _isUnreserved(int byte) =>
      (byte >= 0x41 && byte <= 0x5A) ||
      (byte >= 0x61 && byte <= 0x7A) ||
      (byte >= 0x30 && byte <= 0x39) ||
      byte == 0x2D ||
      byte == 0x2E ||
      byte == 0x5F ||
      byte == 0x7E;

  static final RegExp _safeSegment = RegExp(r'^[A-Za-z0-9_-]+$');
  static final RegExp _upperHex = RegExp(r'^[0-9A-F]{2}$');
  static final RegExp _uuidV7 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  static const Set<String> _staticRoutes = <String>{
    '/today',
    '/tasks',
    '/tasks/today',
    '/tasks/upcoming',
    '/tasks/completed',
    '/goals',
    '/learn',
    '/habits',
    '/notes',
    '/planner',
    '/focus',
    '/fitness',
    '/insights',
    '/recovery',
    '/account-sync',
    '/search',
    '/settings',
    '/settings/general',
    '/settings/appearance',
    '/settings/accessibility',
    '/settings/privacy',
    '/settings/areas',
  };

  static const Set<String> _nonIdRouteSegments = <String>{
    'today',
    'tasks',
    'upcoming',
    'completed',
    'filter',
    'goals',
    'roadmap',
    'learn',
    'item',
    'habits',
    'notes',
    'planner',
    'focus',
    'fitness',
    'insights',
    'recovery',
    'search',
    'settings',
    'general',
    'appearance',
    'accessibility',
    'privacy',
    'areas',
  };
}
