import Foundation

/// A single glanceable line, mirroring the Dart `WidgetSnapshotItem`.
struct WidgetSnapshotItem: Decodable, Hashable {
  let id: String
  let title: String
  let subtitle: String?
  let isComplete: Bool
  let countdownRemainingSeconds: Int?

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case subtitle
    case isComplete = "complete"
    case countdownRemainingSeconds = "countdown_seconds"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    title = try c.decode(String.self, forKey: .title)
    subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
    isComplete = (try c.decodeIfPresent(Bool.self, forKey: .isComplete)) ?? false
    countdownRemainingSeconds = try c.decodeIfPresent(Int.self, forKey: .countdownRemainingSeconds)
  }
}

/// The redacted, versioned, local-only snapshot the app publishes for one
/// surface (mirror of the Dart `WidgetSnapshot`).
///
/// [load] reads the canonical payload from the shared App Group container and
/// fails safe: a newer `version` or malformed bytes yield `nil` so the widget
/// keeps a neutral state instead of crashing (testing.md §10). It never opens
/// the encrypted database (R-WIDGET-002).
struct WidgetSnapshot: Decodable, Hashable {
  let version: Int
  let surfaceWire: String
  let profileId: String
  let generatedAtUtcMicros: Int64
  let stalenessThresholdSeconds: Int64
  let redacted: Bool
  let items: [WidgetSnapshotItem]

  enum CodingKeys: String, CodingKey {
    case version
    case surfaceWire = "surface"
    case profileId = "profile_id"
    case generatedAtUtcMicros = "generated_at_utc_micros"
    case stalenessThresholdSeconds = "staleness_threshold_seconds"
    case redacted
    case items
  }

  /// True when the snapshot is older than its staleness threshold.
  func isStale(nowUtcMicros: Int64) -> Bool {
    let ageMicros = nowUtcMicros - generatedAtUtcMicros
    if ageMicros <= 0 { return false } // future stamp (clock skew) => fresh
    return ageMicros > stalenessThresholdSeconds * 1_000_000
  }

  static func load(surfaceWire: String) -> WidgetSnapshot? {
    guard let defaults = UserDefaults(suiteName: WidgetContract.appGroup),
          let raw = defaults.string(forKey: WidgetContract.snapshotStorageKey(surfaceWire)),
          let data = raw.data(using: .utf8)
    else { return nil }
    return decode(data)
  }

  static func decode(_ data: Data) -> WidgetSnapshot? {
    guard let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    else { return nil }
    if snapshot.version > WidgetContract.supportedSnapshotVersion { return nil }
    if snapshot.redacted && !snapshot.items.isEmpty { return nil }
    return snapshot
  }

  static func readSecret() -> String? {
    UserDefaults(suiteName: WidgetContract.appGroup)?
      .string(forKey: WidgetContract.secretStorageKey)
  }
}
