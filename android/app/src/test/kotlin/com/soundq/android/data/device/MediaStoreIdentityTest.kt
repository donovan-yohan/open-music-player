package com.soundq.android.data.device

import org.junit.Assert.*
import org.junit.Test

/** One MediaStore row (id 41 on external_primary) reached through each collection a provider can hand out. */
class MediaStoreIdentityTest {
    private data class Row(val id: Long, val volume: String, val generation: Long, val audio: Boolean)
    private class Provider(vararg rows: Row) : MediaStoreRows {
        val rows = rows.toList()
        val reads = mutableListOf<String>()
        private fun find(uri: String): Row {
            val segments = uri.removePrefix("content://media/").split('/')
            val row = rows.single { it.id == segments.last().toLong() }
            // "external" is the union of external volumes; any other volume must be the row's own.
            check(segments[0] == "external" || segments[0] == row.volume) { "No row" }
            if (segments.size == 4 && segments[1] == "audio") check(row.audio) { "Not in the audio index" }
            return row
        }
        override fun row(uri: String): MediaRowFacts { reads += uri; return find(uri).let { MediaRowFacts(it.generation, it.volume) } }
        override fun indexedAudio(volume: String, id: Long): String? =
            rows.singleOrNull { it.id == id && it.volume == volume && it.audio }?.let { "content://media/$volume/audio/media/$id" }
        override fun key(uri: String, volume: String, facts: MediaRowFacts) = "media:v-$volume:$uri:${facts.generation}"
    }
    private fun identity(uri: String, provider: MediaStoreRows) =
        MediaStoreIdentity.of(uri, uri.removePrefix("content://media/").split('/'), provider)

    @Test fun indexedScanAndFileGrantRoutesToOneRowShareOneKey() {
        val provider = Provider(Row(41, "external_primary", 7, audio = true))
        val indexed = identity("content://media/external_primary/audio/media/41", provider)
        val downloads = identity("content://media/external/downloads/41", provider)
        // Before this change the file grant keyed the row by its downloads URI: a second Library row.
        assertEquals("media:v-external_primary:content://media/external_primary/audio/media/41:7", indexed.key)
        assertEquals(indexed.key, downloads.key)
        assertEquals(setOf("media:v-external:content://media/external/downloads/41:7"), downloads.former)
        assertEquals(indexed.key, identity("content://media/external/file/41", provider).key)
        assertEquals(indexed.key, identity("content://media/external/audio/media/41", provider).key)
        assertEquals(indexed.key, identity("content://media/external_primary/downloads/41", provider).key)
    }

    @Test fun indexedKeysAreUnchangedAndReadOnlyTheirOwnRow() {
        val provider = Provider(Row(41, "external_primary", 7, audio = true))
        val indexed = identity("content://media/external_primary/audio/media/41", provider)
        assertEquals(emptySet<String>(), indexed.former)
        assertEquals(listOf("content://media/external_primary/audio/media/41"), provider.reads)
    }

    @Test fun rowsOutsideTheAudioIndexKeepTheirKey() {
        val provider = Provider(Row(52, "external_primary", 3, audio = false))
        val download = identity("content://media/external/downloads/52", provider)
        assertEquals("media:v-external:content://media/external/downloads/52:3", download.key)
        assertEquals(emptySet<String>(), download.former)
    }

    @Test fun differentRowsAndIncarnationsStayDistinct() {
        val provider = Provider(Row(41, "external_primary", 7, audio = true), Row(42, "external_primary", 7, audio = true))
        assertNotEquals(identity("content://media/external/downloads/41", provider).key, identity("content://media/external/downloads/42", provider).key)
        // A provider reporting a different incarnation for the indexed row is not proof of one object.
        val reused = object : MediaStoreRows by provider {
            override fun row(uri: String) = provider.row(uri).let { if ("/audio/" in uri) it.copy(generation = 8) else it }
        }
        val legacy = identity("content://media/external/downloads/41", reused)
        assertEquals("media:v-external:content://media/external/downloads/41:7", legacy.key)
        assertEquals(emptySet<String>(), legacy.former)
    }

    @Test fun unknownVolumeOrIdKeepsTheLegacyKey() {
        val noVolume = object : MediaStoreRows {
            override fun row(uri: String) = MediaRowFacts(null, null)
            override fun indexedAudio(volume: String, id: Long): String? = error("Not consulted")
            override fun key(uri: String, volume: String, facts: MediaRowFacts) = "provider:$uri"
        }
        assertEquals(ProviderIdentity("provider:content://media/external/downloads/41"), identity("content://media/external/downloads/41", noVolume))
        assertEquals(ProviderIdentity("provider:content://media/external/downloads"), identity("content://media/external/downloads", noVolume))
    }
}
