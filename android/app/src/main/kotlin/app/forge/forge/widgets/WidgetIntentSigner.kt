package app.forge.forge.widgets

/**
 * Android mirror of the Dart `KeyedHashWidgetIntentSigner`
 * (lib/features/widgets/infrastructure/keyed_hash_widget_intent_signer.dart).
 *
 * A widget tap must authenticate its intent so the Dart bridge can reject a
 * spoofed link before any command runs (R-WIDGET-003). This produces the SAME
 * tag the Dart signer produces for the same canonical payload and shared
 * secret, using unsigned 64-bit (`ULong`) lanes so multiplication wraps mod
 * 2^64 exactly like the masked Dart arithmetic.
 *
 * NOTE: cross-platform tag agreement is validated on-device by the spoof/stale
 * platform tests (task 11.4, MANUAL-WIDGET-SIGNER-CROSSCHECK). Hardening the
 * secret behind the Android keystore is tracked as MANUAL-WIDGET-SECRET.
 */
class WidgetIntentSigner(private val secret: String) {
    init {
        require(secret.length >= 16) {
            "Widget bridge secret must be at least 16 characters."
        }
    }

    fun sign(canonicalPayload: String): String {
        val keyBytes = secret.toByteArray(Charsets.UTF_8)
        val ipad = ByteArray(keyBytes.size) { (keyBytes[it].toInt() xor 0x36).toByte() }
        val opad = ByteArray(keyBytes.size) { (keyBytes[it].toInt() xor 0x5c).toByte() }
        val message = canonicalPayload.toByteArray(Charsets.UTF_8)

        val tag = StringBuilder()
        for (seed in LANE_SEEDS) {
            val inner = hash(seed, ipad + message)
            val outer = hash(seed, opad + toBytes(inner))
            tag.append(outer.toString(16).padStart(16, '0'))
        }
        return tag.toString()
    }

    fun verify(canonicalPayload: String, token: String): Boolean =
        constantTimeEquals(sign(canonicalPayload), token)

    private fun hash(seed: ULong, bytes: ByteArray): ULong {
        var h = seed
        for (b in bytes) {
            h = h xor (b.toLong() and 0xff).toULong()
            h *= FNV_PRIME
        }
        return h
    }

    private fun toBytes(value: ULong): ByteArray {
        val out = ByteArray(8)
        var shift = 56
        for (i in 0 until 8) {
            out[i] = ((value shr shift) and 0xffUL).toByte()
            shift -= 8
        }
        return out
    }

    private fun constantTimeEquals(a: String, b: String): Boolean {
        if (a.length != b.length) return false
        var diff = 0
        for (i in a.indices) {
            diff = diff or (a[i].code xor b[i].code)
        }
        return diff == 0
    }

    companion object {
        private val LANE_SEEDS = listOf(
            0xcbf29ce484222325UL,
            0x84222325cbf29ce4UL,
            0x9e3779b97f4a7c15UL,
            0xff51afd7ed558ccdUL,
        )
        private const val FNV_PRIME = 0x100000001b3UL
    }
}
