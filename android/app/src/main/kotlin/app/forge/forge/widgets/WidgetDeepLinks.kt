package app.forge.forge.widgets

import android.net.Uri
import java.util.UUID

/**
 * Builds the `forge://widget/...` deep links a tap opens (R-WIDGET-003).
 *
 * The URI shape and query parameters mirror the Dart `WidgetDeepLink`
 * (lib/features/widgets/domain/widget_deep_link.dart); the Dart bridge parses
 * the link back into an untrusted intent and re-verifies signature, profile
 * binding, and freshness before any command runs.
 */
object WidgetDeepLinks {
    /**
     * Builds a signed action link for a widget tap. [issuedAtUtcMicros] and
     * [intentId] make the tap fresh and idempotent; a double-tap re-delivers
     * the same intent id and the Dart bridge returns the same committed result.
     */
    fun buildActionUri(
        signer: WidgetIntentSigner,
        actionWire: String,
        surfaceWire: String,
        profileId: String,
        targetEntityId: String,
        issuedAtUtcMicros: Long,
        intentId: String = UUID.randomUUID().toString(),
    ): Uri {
        val canonical = canonicalPayload(
            actionWire = actionWire,
            intentId = intentId,
            issuedAtUtcMicros = issuedAtUtcMicros,
            profileId = profileId,
            surfaceWire = surfaceWire,
            targetEntityId = targetEntityId,
        )
        val token = signer.sign(canonical)
        return Uri.Builder()
            .scheme(WidgetContract.DEEP_LINK_SCHEME)
            .authority(WidgetContract.DEEP_LINK_HOST)
            .appendPath(WidgetContract.DEEP_LINK_ACTION_PATH)
            .appendQueryParameter(WidgetContract.PARAM_ACTION, actionWire)
            .appendQueryParameter(WidgetContract.PARAM_INTENT_ID, intentId)
            .appendQueryParameter(WidgetContract.PARAM_ISSUED_AT, issuedAtUtcMicros.toString())
            .appendQueryParameter(WidgetContract.PARAM_PROFILE_ID, profileId)
            .appendQueryParameter(WidgetContract.PARAM_SURFACE, surfaceWire)
            .appendQueryParameter(WidgetContract.PARAM_TARGET, targetEntityId)
            .appendQueryParameter(WidgetContract.PARAM_TOKEN, token)
            .build()
    }

    /** Builds a plain "open this surface" link (no mutation). */
    fun buildOpenUri(surfaceWire: String): Uri =
        Uri.Builder()
            .scheme(WidgetContract.DEEP_LINK_SCHEME)
            .authority(WidgetContract.DEEP_LINK_HOST)
            .appendPath(WidgetContract.DEEP_LINK_OPEN_PATH)
            .appendQueryParameter(WidgetContract.PARAM_SURFACE, surfaceWire)
            .build()

    /**
     * The canonical, signable payload. Keys are sorted and the token is
     * excluded, matching `WidgetIntent.canonicalPayload()` on the Dart side so
     * both platforms sign identical bytes.
     */
    private fun canonicalPayload(
        actionWire: String,
        intentId: String,
        issuedAtUtcMicros: Long,
        profileId: String,
        surfaceWire: String,
        targetEntityId: String,
    ): String {
        // Minimal, deterministic JSON with sorted keys and JSON-escaped values.
        return buildString {
            append('{')
            append("\"action\":").append(jsonString(actionWire)).append(',')
            append("\"intent_id\":").append(jsonString(intentId)).append(',')
            append("\"issued_at_utc_micros\":").append(issuedAtUtcMicros).append(',')
            append("\"profile_id\":").append(jsonString(profileId)).append(',')
            append("\"surface\":").append(jsonString(surfaceWire)).append(',')
            append("\"target_entity_id\":").append(jsonString(targetEntityId))
            append('}')
        }
    }

    private fun jsonString(value: String): String {
        val sb = StringBuilder(value.length + 2)
        sb.append('"')
        for (c in value) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> if (c < ' ') {
                    sb.append("\\u").append(c.code.toString(16).padStart(4, '0'))
                } else {
                    sb.append(c)
                }
            }
        }
        sb.append('"')
        return sb.toString()
    }
}
