package app.forge.forge.widgets

import org.json.JSONObject

/** A single glanceable line, mirroring the Dart `WidgetSnapshotItem`. */
data class WidgetSnapshotItem(
    val id: String,
    val title: String,
    val subtitle: String?,
    val isComplete: Boolean,
    val countdownRemainingSeconds: Long?,
)

/**
 * The redacted, versioned, local-only snapshot the app publishes for one
 * surface (mirror of the Dart `WidgetSnapshot`).
 *
 * Decoding is version-aware and fails safe: a payload whose `version` exceeds
 * [WidgetContract.SUPPORTED_SNAPSHOT_VERSION] (a newer app wrote a container an
 * older widget reads) or that is malformed returns `null`, so the widget keeps
 * its last good render / neutral state rather than crashing (testing.md §10).
 */
data class WidgetSnapshot(
    val version: Int,
    val surfaceWire: String,
    val profileId: String,
    val generatedAtUtcMicros: Long,
    val stalenessThresholdSeconds: Long,
    val redacted: Boolean,
    val items: List<WidgetSnapshotItem>,
) {
    /** True when the snapshot is older than its staleness threshold. */
    fun isStaleAt(nowUtcMicros: Long): Boolean {
        val ageMicros = nowUtcMicros - generatedAtUtcMicros
        if (ageMicros <= 0L) return false // future stamp (clock skew) => fresh
        return ageMicros > stalenessThresholdSeconds * 1_000_000L
    }

    companion object {
        /**
         * Parses a canonical snapshot JSON string, or returns null on any
         * malformed / newer-version input. Never throws.
         */
        fun decode(raw: String?): WidgetSnapshot? {
            if (raw.isNullOrEmpty()) return null
            return try {
                val json = JSONObject(raw)
                val version = json.getInt("version")
                if (version > WidgetContract.SUPPORTED_SNAPSHOT_VERSION) return null
                val redacted = json.getBoolean("redacted")
                val itemsJson = json.getJSONArray("items")
                val items = ArrayList<WidgetSnapshotItem>(itemsJson.length())
                for (i in 0 until itemsJson.length()) {
                    val item = itemsJson.getJSONObject(i)
                    items.add(
                        WidgetSnapshotItem(
                            id = item.getString("id"),
                            title = item.getString("title"),
                            subtitle = if (item.has("subtitle")) {
                                item.getString("subtitle")
                            } else {
                                null
                            },
                            isComplete = item.optBoolean("complete", false),
                            countdownRemainingSeconds = if (item.has("countdown_seconds")) {
                                item.getLong("countdown_seconds")
                            } else {
                                null
                            },
                        ),
                    )
                }
                // A redacted snapshot must carry no content.
                if (redacted && items.isNotEmpty()) return null
                WidgetSnapshot(
                    version = version,
                    surfaceWire = json.getString("surface"),
                    profileId = json.getString("profile_id"),
                    generatedAtUtcMicros = json.getLong("generated_at_utc_micros"),
                    stalenessThresholdSeconds = json.getLong("staleness_threshold_seconds"),
                    redacted = redacted,
                    items = items,
                )
            } catch (_: Throwable) {
                null
            }
        }
    }
}
