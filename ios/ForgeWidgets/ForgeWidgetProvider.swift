import WidgetKit
import SwiftUI

/// The timeline entry rendered by a Forge widget. Carries the last loaded
/// snapshot (or nil) plus the read-time freshness decision.
struct ForgeWidgetEntry: TimelineEntry {
  let date: Date
  let surfaceWire: String
  let snapshot: WidgetSnapshot?
  let isStale: Bool
}

/// A snapshot-backed timeline provider (R-WIDGET-002/003).
///
/// Reads ONLY the redacted shared-container snapshot the app published; it
/// never opens the encrypted database. The app nudges `reloadAllTimelines()`
/// after each publish, and a periodic refresh keeps the stale indicator honest.
struct ForgeWidgetProvider: TimelineProvider {
  let surfaceWire: String

  func placeholder(in context: Context) -> ForgeWidgetEntry {
    ForgeWidgetEntry(date: Date(), surfaceWire: surfaceWire, snapshot: nil, isStale: false)
  }

  func getSnapshot(in context: Context, completion: @escaping (ForgeWidgetEntry) -> Void) {
    completion(makeEntry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<ForgeWidgetEntry>) -> Void) {
    let entry = makeEntry()
    // Refresh in 15 minutes so the stale badge appears without a publish.
    let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
    completion(Timeline(entries: [entry], policy: .after(next)))
  }

  private func makeEntry() -> ForgeWidgetEntry {
    let snapshot = WidgetSnapshot.load(surfaceWire: surfaceWire)
    let nowMicros = Int64(Date().timeIntervalSince1970 * 1_000_000)
    return ForgeWidgetEntry(
      date: Date(),
      surfaceWire: surfaceWire,
      snapshot: snapshot,
      isStale: snapshot?.isStale(nowUtcMicros: nowMicros) ?? false)
  }
}
