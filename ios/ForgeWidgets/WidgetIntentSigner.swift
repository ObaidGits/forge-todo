import Foundation

/// WidgetKit-extension mirror of the Dart `KeyedHashWidgetIntentSigner`
/// (lib/features/widgets/infrastructure/keyed_hash_widget_intent_signer.dart).
///
/// Produces the SAME authentication tag the Dart signer produces for the same
/// canonical payload and shared secret, using `UInt64` lanes so multiplication
/// wraps mod 2^64 exactly like the masked Dart arithmetic. A widget tap uses it
/// to authenticate its intent so the Dart bridge can reject a spoofed link
/// before any command runs (R-WIDGET-003).
///
/// Cross-platform tag agreement is validated on-device by the spoof/stale
/// platform tests (task 11.4, MANUAL-WIDGET-SIGNER-CROSSCHECK).
struct WidgetIntentSigner {
  let secret: String

  private static let laneSeeds: [UInt64] = [
    0xcbf29ce484222325,
    0x84222325cbf29ce4,
    0x9e3779b97f4a7c15,
    0xff51afd7ed558ccd,
  ]
  private static let fnvPrime: UInt64 = 0x100000001b3

  func sign(_ canonicalPayload: String) -> String {
    let keyBytes = Array(secret.utf8)
    let ipad = keyBytes.map { $0 ^ 0x36 }
    let opad = keyBytes.map { $0 ^ 0x5c }
    let message = Array(canonicalPayload.utf8)

    var tag = ""
    for seed in Self.laneSeeds {
      let inner = hash(seed: seed, bytes: ipad + message)
      let outer = hash(seed: seed, bytes: opad + toBytes(inner))
      tag += String(format: "%016llx", outer)
    }
    return tag
  }

  private func hash(seed: UInt64, bytes: [UInt8]) -> UInt64 {
    var h = seed
    for b in bytes {
      h ^= UInt64(b)
      h = h &* Self.fnvPrime
    }
    return h
  }

  private func toBytes(_ value: UInt64) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 8)
    var shift: UInt64 = 56
    for i in 0..<8 {
      out[i] = UInt8((value >> shift) & 0xff)
      if shift >= 8 { shift -= 8 }
    }
    return out
  }
}
