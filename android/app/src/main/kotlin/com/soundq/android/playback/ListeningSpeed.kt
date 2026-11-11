package com.soundq.android.playback

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.io.File
import java.security.MessageDigest

internal const val SET_LISTENING_SPEED = "soundq.listening.speed.v1"
internal const val LISTENING_SPEED_STATE = "listeningSpeed"

/** Why ordinary speed is unavailable for the current selection. */
@Serializable enum class ListeningSpeedUnavailable { Arrangement, Jam, Source }

/** Service-published accepted listening speed for exactly [occurrence]. [accepted] is the
 * native engine's applied pace (or the stored preference that will apply at load), never a
 * requested value. Source position/duration remain original-source time. */
@Serializable data class ListeningSpeedState(
    val occurrence: String, val accepted: Double, val min: Double, val max: Double,
    val unavailable: ListeningSpeedUnavailable? = null,
)

internal object ListeningSpeedPolicy {
    const val STEP = 0.05
    /** Product step quantisation; null outside the native capability. */
    fun quantise(value: Double, min: Double, max: Double): Double? {
        if (!value.isFinite() || !(min < 1.0 && max > 1.0)) return null
        val stepped = Math.round(value / STEP) * STEP
        val rounded = Math.round(stepped * 100) / 100.0
        return rounded.takeIf { it >= min - 1e-9 && it <= max + 1e-9 }
    }
}

/** Stable per-track identity. Device files use content identity (survives re-import and
 * new incarnations); server tracks are scoped to endpoint + account. Only hashes persist. */
@JvmInline value class ListeningSpeedKey private constructor(val value: String) {
    companion object {
        private fun hash(vararg parts: String) = MessageDigest.getInstance("SHA-256")
            .digest(parts.joinToString("\u0000").toByteArray()).joinToString("") { "%02x".format(it) }
        fun device(ref: PlaybackRef.Device) = ListeningSpeedKey("d:" + hash("device", ref.sha256, ref.bytes.toString()))
        fun server(endpoint: String, account: String, track: Long) = ListeningSpeedKey("s:" + hash("server", endpoint, account, track.toString()))
    }
}

/** On-device per-track preference. Never-configured tracks are normal speed; storing 1.0x
 * deletes the entry (Reset). Bounded, oldest entries evicted first. Main-thread owned map;
 * writes are atomic file replacement. */
internal class ListeningSpeedPreferences(private val file: File, private val capacity: Int = 2000) {
    private val speeds = LinkedHashMap<String, Double>()
    init {
        runCatching {
            if (file.isFile) {
                val root = Json.parseToJsonElement(file.readText()).jsonObject
                require(root["version"]?.jsonPrimitive?.int == 1)
                root.getValue("speeds").jsonObject.entries.take(capacity).forEach { (key, value) ->
                    val speed = value.jsonPrimitive.double
                    if ((key.startsWith("d:") || key.startsWith("s:")) && speed.isFinite() && speed in 0.25..4.0 && speed != 1.0) speeds[key] = speed
                }
            }
        }.onFailure { speeds.clear() }
    }
    @Synchronized fun speed(key: ListeningSpeedKey): Double? = speeds[key.value]
    /** Updates the preference and atomically replaces the file. Returns false when the
     * file could not be replaced; the previous file is then left untouched (never
     * truncated) and the in-memory value still applies for this process. */
    @Synchronized fun set(key: ListeningSpeedKey, speed: Double): Boolean {
        speeds.remove(key.value)
        if (speed != 1.0) speeds[key.value] = speed
        while (speeds.size > capacity) speeds.remove(speeds.keys.first())
        val text = buildJsonObject {
            put("version", 1)
            put("speeds", buildJsonObject { speeds.forEach { (k, v) -> put(k, v) } })
        }.toString()
        val temporary = File(file.parentFile, file.name + ".tmp")
        val replaced = runCatching {
            file.parentFile?.mkdirs()
            temporary.writeText(text)
            temporary.renameTo(file)
        }.getOrDefault(false)
        if (!replaced) temporary.delete()
        return replaced
    }
}
