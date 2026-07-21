import WidgetKit
import SwiftUI

/// Shared SwiftUI rendering for every Forge surface, honouring the snapshot's
/// honest state (R-WIDGET-003/004):
///
///   * redacted     -> privacy placeholder (no titles, no counts);
///   * stale        -> a "Stale" badge next to the last good content;
///   * missing/undecodable -> a neutral "Open Forge" placeholder.
///
/// Check rows are wrapped in a `Link` to a signed `forge://widget/intent` URL;
/// the app verifies and commits, then republishes a fresh snapshot. The widget
/// never optimistically mutates.
struct ForgeWidgetView: View {
  let entry: ForgeWidgetEntry
  let title: String
  let actionWire: String?
  let exposesContent: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      content
      Spacer(minLength: 0)
    }
    .padding(12)
    .widgetURL(WidgetDeepLinks.buildOpenURL(surfaceWire: entry.surfaceWire))
  }

  private var header: some View {
    HStack {
      Text(title).font(.headline).lineLimit(1)
      Spacer()
      if entry.isStale {
        Text("Stale").font(.caption2).foregroundColor(.secondary)
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    if let snapshot = entry.snapshot {
      if snapshot.redacted {
        placeholder("Locked — open Forge to view")
      } else if !exposesContent {
        placeholder("Tap to capture a note")
      } else if snapshot.items.isEmpty {
        placeholder("Nothing for today")
      } else {
        rows(snapshot)
      }
    } else {
      placeholder("Open Forge")
    }
  }

  private func placeholder(_ text: String) -> some View {
    Text(text).font(.subheadline).foregroundColor(.secondary)
  }

  @ViewBuilder
  private func rows(_ snapshot: WidgetSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(snapshot.items.prefix(5), id: \.id) { item in
        row(item, profileId: snapshot.profileId)
      }
    }
  }

  @ViewBuilder
  private func row(_ item: WidgetSnapshotItem, profileId: String) -> some View {
    let line = HStack(alignment: .top, spacing: 8) {
      Image(systemName: item.isComplete ? "checkmark.square.fill" : "square")
        .foregroundColor(item.isComplete ? .accentColor : .secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(item.title).font(.subheadline).lineLimit(1)
        if let subtitle = item.subtitle {
          Text(subtitle).font(.caption2).foregroundColor(.secondary).lineLimit(1)
        } else if let seconds = item.countdownRemainingSeconds {
          Text(formatCountdown(seconds)).font(.caption2).foregroundColor(.secondary)
        }
      }
      Spacer()
    }

    if let actionWire = actionWire, !item.isComplete,
       let secret = WidgetSnapshot.readSecret(),
       let url = WidgetDeepLinks.buildActionURL(
        signer: WidgetIntentSigner(secret: secret),
        actionWire: actionWire,
        surfaceWire: entry.surfaceWire,
        profileId: profileId,
        targetEntityId: item.id,
        issuedAtUtcMicros: Int64(Date().timeIntervalSince1970 * 1_000_000)) {
      Link(destination: url) { line }
    } else {
      line
    }
  }

  private func formatCountdown(_ remainingSeconds: Int) -> String {
    let clamped = max(0, remainingSeconds)
    let hours = clamped / 3600
    let minutes = (clamped % 3600) / 60
    let seconds = clamped % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
  }
}
