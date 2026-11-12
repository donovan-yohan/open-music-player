package com.soundq.android.data.device

/** A provider object key plus former keys the provider proves name the same object. [former] lets the
 * catalog fold rows stored under an earlier key into this one; it is never derived from names or bytes. */
internal data class ProviderIdentity(val key: String, val former: Set<String> = emptySet()) {
    val all: Set<String> get() = former + key
}

/** What MediaStore reports for one row. [generation] is GENERATION_ADDED (API 30+), [volume] its concrete
 * VOLUME_NAME. Null when the provider does not expose that column on this release. */
internal data class MediaRowFacts(val generation: Long?, val volume: String?)

/** Provider reads behind [MediaStoreIdentity]; production queries the real resolver. */
internal interface MediaStoreRows {
    /** Throws when the row cannot be observed. */
    fun row(uri: String): MediaRowFacts
    /** The audio index URI for row [id] on [volume], when that row is in the audio index. */
    fun indexedAudio(volume: String, id: Long): String?
    /** The pre-existing key shape for [uri] read through [volume]. */
    fun key(uri: String, volume: String, facts: MediaRowFacts): String
}

/** One MediaStore row can be reached through several collections and volume aliases: the indexed scan lists
 * `external_primary/audio/media/<id>`, while a file grant resolves to e.g. `external/downloads/<id>`. Both
 * name the same row, so the audio-index URI on the row's concrete volume is canonical. That is the URI the
 * indexed scan already keys on, so indexed identities are unchanged; other routes to an audio-index row
 * adopt it and keep their old key as former. Rows outside the audio index keep their key: the indexed scan
 * never lists them, so they cannot duplicate one of its rows. */
internal object MediaStoreIdentity {
    private const val VOLUME_EXTERNAL = "external"
    fun of(uri: String, segments: List<String>, rows: MediaStoreRows): ProviderIdentity {
        val volume = segments.firstOrNull() ?: throw java.io.IOException("Provider volume unavailable")
        val facts = rows.row(uri)
        val legacy = rows.key(uri, volume, facts)
        val id = segments.lastOrNull()?.toLongOrNull()?.takeIf { it >= 0 } ?: return ProviderIdentity(legacy)
        val alreadyIndexed = segments.size == 4 && segments[1] == "audio" && segments[2] == "media" && volume != VOLUME_EXTERNAL
        if (alreadyIndexed) return ProviderIdentity(legacy)
        val concrete = facts.volume?.takeIf { it.isNotBlank() && it != VOLUME_EXTERNAL } ?: return ProviderIdentity(legacy)
        val indexed = rows.indexedAudio(concrete, id) ?: return ProviderIdentity(legacy)
        if (indexed == uri) return ProviderIdentity(legacy)
        val canonicalFacts = rows.row(indexed)
        // Same row id on another incarnation is a different object.
        if (canonicalFacts.generation != facts.generation) return ProviderIdentity(legacy)
        val canonical = rows.key(indexed, concrete, canonicalFacts)
        return ProviderIdentity(canonical, if (canonical == legacy) emptySet() else setOf(legacy))
    }
}
