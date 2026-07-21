import Foundation

/// Builds the `forge://widget/...` deep links a tap opens (R-WIDGET-003).
///
/// The URI shape and query parameters mirror the Dart `WidgetDeepLink`
/// (lib/features/widgets/domain/widget_deep_link.dart); the Dart bridge parses
/// the link back into an untrusted intent and re-verifies signature, profile
/// binding, and freshness before any command runs.
enum WidgetDeepLinks {
  /// Builds a signed action link for a widget tap. [issuedAtUtcMicros] and
  /// [intentId] make the tap fresh and idempotent.
  static func buildActionURL(
    signer: WidgetIntentSigner,
    actionWire: String,
    surfaceWire: String,
    profileId: String,
    targetEntityId: String,
    issuedAtUtcMicros: Int64,
    intentId: String = UUID().uuidString
  ) -> URL? {
    let canonical = canonicalPayload(
      actionWire: actionWire,
      intentId: intentId,
      issuedAtUtcMicros: issuedAtUtcMicros,
      profileId: profileId,
      surfaceWire: surfaceWire,
      targetEntityId: targetEntityId)
    let token = signer.sign(canonical)

    var components = URLComponents()
    components.scheme = WidgetContract.deepLinkScheme
    components.host = WidgetContract.deepLinkHost
    components.path = "/\(WidgetContract.deepLinkActionPath)"
    components.queryItems = [
      URLQueryItem(name: WidgetContract.paramAction, value: actionWire),
      URLQueryItem(name: WidgetContract.paramIntentId, value: intentId),
      URLQueryItem(name: WidgetContract.paramIssuedAt, value: String(issuedAtUtcMicros)),
      URLQueryItem(name: WidgetContract.paramProfileId, value: profileId),
      URLQueryItem(name: WidgetContract.paramSurface, value: surfaceWire),
      URLQueryItem(name: WidgetContract.paramTarget, value: targetEntityId),
      URLQueryItem(name: WidgetContract.paramToken, value: token),
    ]
    return components.url
  }

  /// Builds a plain "open this surface" link (no mutation).
  static func buildOpenURL(surfaceWire: String) -> URL? {
    var components = URLComponents()
    components.scheme = WidgetContract.deepLinkScheme
    components.host = WidgetContract.deepLinkHost
    components.path = "/\(WidgetContract.deepLinkOpenPath)"
    components.queryItems = [
      URLQueryItem(name: WidgetContract.paramSurface, value: surfaceWire)
    ]
    return components.url
  }

  /// The canonical, signable payload. Keys are sorted and the token excluded,
  /// matching `WidgetIntent.canonicalPayload()` on the Dart side so both
  /// platforms sign identical bytes.
  private static func canonicalPayload(
    actionWire: String,
    intentId: String,
    issuedAtUtcMicros: Int64,
    profileId: String,
    surfaceWire: String,
    targetEntityId: String
  ) -> String {
    var out = "{"
    out += "\"action\":\(jsonString(actionWire)),"
    out += "\"intent_id\":\(jsonString(intentId)),"
    out += "\"issued_at_utc_micros\":\(issuedAtUtcMicros),"
    out += "\"profile_id\":\(jsonString(profileId)),"
    out += "\"surface\":\(jsonString(surfaceWire)),"
    out += "\"target_entity_id\":\(jsonString(targetEntityId))"
    out += "}"
    return out
  }

  private static func jsonString(_ value: String) -> String {
    var sb = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": sb += "\\\""
      case "\\": sb += "\\\\"
      case "\n": sb += "\\n"
      case "\r": sb += "\\r"
      case "\t": sb += "\\t"
      default:
        if scalar.value < 0x20 {
          sb += String(format: "\\u%04x", scalar.value)
        } else {
          sb.unicodeScalars.append(scalar)
        }
      }
    }
    sb += "\""
    return sb
  }
}
