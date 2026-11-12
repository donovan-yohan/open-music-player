package com.soundq.android.data.device

import org.junit.Assert.*
import org.junit.Test

class LegacyPickerIdentityTest {
    private val root = { volume: String -> if (volume == "primary") "/storage/emulated/0" else "/storage/$volume" }
    private fun route(key: String) = LegacyPickerIdentity.route(key, root)

    @Test fun mediaStoreKeysNameTheirRow() {
        assertEquals(LegacyRoute.Media("content://media/external/downloads/41"), route("media:1.0.31:content://media/external/downloads/41:1040"))
        assertEquals(LegacyRoute.Media("content://media/external_primary/file/9"), route("media:ab:cd:content://media/external_primary/file/9:3"))
        assertEquals(LegacyRoute.Media("content://media/external/audio/media/5"), route("provider:content://media/external/audio/media/5"))
        assertNull(route("media:v:content://media/external/downloads/41"))
        assertNull(route("media:v:file:///sdcard/a.mp3:1"))
    }

    @Test fun externalStorageDocumentsAreTheirPath() {
        assertEquals(LegacyRoute.Path("/storage/emulated/0/Music/Mixes/a b.mp3"), route("document:com.android.externalstorage.documents:primary:Music/Mixes/a b.mp3"))
        assertEquals(LegacyRoute.Path("/storage/1A2B-3C4D/Download/x.flac"), route("document:com.android.externalstorage.documents:1A2B-3C4D:Download/x.flac"))
        assertNull("A root is not a file", route("document:com.android.externalstorage.documents:primary:"))
        assertNull(route("document:com.android.externalstorage.documents:primary:Music/../../data/x.mp3"))
    }

    @Test fun downloadAndMediaDocumentsMapWhereTheyNameAFileOrRow() {
        assertEquals(LegacyRoute.Path("/storage/emulated/0/Download/x.mp3"), route("document:com.android.providers.downloads.documents:raw:/storage/emulated/0/Download/x.mp3"))
        assertEquals(LegacyRoute.Media("content://media/external/file/77"), route("document:com.android.providers.downloads.documents:msf:77"))
        assertEquals(LegacyRoute.Media("content://media/external/audio/media/12"), route("document:com.android.providers.media.documents:audio:12"))
        assertNull(route("document:com.android.providers.downloads.documents:31"))
        assertNull(route("document:com.android.providers.media.documents:image:12"))
    }

    @Test fun otherProvidersCannotBeProved() {
        assertNull(route("document:com.google.android.apps.docs.storage:acc=1;doc=encoded"))
        assertNull(route("provider:content://com.example.cloud/audio/1"))
        assertNull(route("unknown"))
    }
}
