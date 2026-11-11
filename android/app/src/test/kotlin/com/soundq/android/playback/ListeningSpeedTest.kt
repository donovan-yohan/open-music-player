package com.soundq.android.playback

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ListeningSpeedTest {
    @get:Rule val folder = TemporaryFolder()
    private val device = PlaybackRef.Device("3f1c2a6e-8a51-4d38-9a8e-1b4c4c0f8a11", "a".repeat(64), 1234, 7)

    @Test fun keysUseStableSourceIdentityNotOccurrenceOrIncarnation() {
        val a = ListeningSpeedKey.device(device)
        // Re-import/new incarnation or library row id of the same bytes keeps the preference.
        assertEquals(a, ListeningSpeedKey.device(device.copy(id = "0b6c7a43-56a2-4f0e-8a87-34c3f7c1f9d2", incarnation = 9)))
        assertNotEquals(a, ListeningSpeedKey.device(device.copy(sha256 = "b".repeat(64))))
        assertNotEquals(a, ListeningSpeedKey.device(device.copy(bytes = 1235)))
        val server = ListeningSpeedKey.server("https://example.test/api/v1", "account-1", 42)
        assertEquals(server, ListeningSpeedKey.server("https://example.test/api/v1", "account-1", 42))
        assertNotEquals(server, ListeningSpeedKey.server("https://example.test/api/v1", "account-2", 42))
        assertNotEquals(server, ListeningSpeedKey.server("https://other.test/api/v1", "account-1", 42))
        assertNotEquals(server, ListeningSpeedKey.server("https://example.test/api/v1", "account-1", 43))
        // No raw account, endpoint or path is written to disk.
        assertFalse(server.value.contains("account-1") || server.value.contains("example"))
    }

    @Test fun quantisesToProductStepsAndRefusesOutOfBounds() {
        assertEquals(1.35, ListeningSpeedPolicy.quantise(1.3499999, 0.5, 2.0)!!, 0.0)
        assertEquals(1.5, ListeningSpeedPolicy.quantise(1.51, 0.5, 2.0)!!, 0.0)
        assertNull(ListeningSpeedPolicy.quantise(2.5, 0.5, 2.0))
        assertNull(ListeningSpeedPolicy.quantise(0.25, 0.5, 2.0))
        assertNull(ListeningSpeedPolicy.quantise(Double.NaN, 0.5, 2.0))
        assertNull(ListeningSpeedPolicy.quantise(1.5, 1.0, 1.0)) // no capability
    }

    @Test fun preferencesPersistPerTrackResetClearsAndNeverConfiguredIsNormal() {
        val file = folder.root.resolve("listening-speed.json")
        val store = ListeningSpeedPreferences(file)
        val a = ListeningSpeedKey.device(device); val b = ListeningSpeedKey.server("https://e.test/api/v1", "x", 1)
        assertNull(store.speed(a))
        store.set(a, 1.5); assertEquals(1.5, store.speed(a)!!, 0.0); assertNull(store.speed(b))
        // Restart restores A and leaves never-configured B at normal.
        val reopened = ListeningSpeedPreferences(file)
        assertEquals(1.5, reopened.speed(a)!!, 0.0); assertNull(reopened.speed(b))
        reopened.set(a, 1.0) // Reset deletes the preference rather than storing 1.0x.
        assertNull(reopened.speed(a)); assertNull(ListeningSpeedPreferences(file).speed(a))
        assertFalse(file.readText().contains(a.value))
    }

    @Test fun corruptOrOutOfRangeStorageIsIgnoredNotApplied() {
        val file = folder.root.resolve("listening-speed.json")
        file.writeText("{not json")
        assertNull(ListeningSpeedPreferences(file).speed(ListeningSpeedKey.device(device)))
        val key = ListeningSpeedKey.device(device)
        file.writeText("{\"version\":1,\"speeds\":{\"${key.value}\":9.0}}")
        assertNull(ListeningSpeedPreferences(file).speed(key))
    }

    @Test fun failedReplacementReportsUnsavedAndKeepsThePreviousFile() {
        val file = folder.root.resolve("listening-speed.json")
        val store = ListeningSpeedPreferences(file)
        val a = ListeningSpeedKey.device(device)
        assertTrue(store.set(a, 1.5))
        val saved = file.readBytes()
        // The replacement temporary cannot be written: report unsaved, never truncate.
        folder.root.resolve("listening-speed.json.tmp").apply { mkdirs(); resolve("held").writeText("x") }
        assertFalse(store.set(a, 0.75))
        assertArrayEquals(saved, file.readBytes())
        assertEquals("applies for this process", 0.75, store.speed(a)!!, 0.0)
        assertEquals(1.5, ListeningSpeedPreferences(file).speed(a)!!, 0.0)
    }

    @Test fun storeIsBoundedOldestFirst() {
        val store = ListeningSpeedPreferences(folder.root.resolve("s.json"), capacity = 3)
        val keys = (1..4).map { ListeningSpeedKey.server("https://e.test/api/v1", "x", it.toLong()) }
        keys.forEach { store.set(it, 1.25) }
        assertNull(store.speed(keys[0])); keys.drop(1).forEach { assertEquals(1.25, store.speed(it)!!, 0.0) }
    }
}
