package com.soundq.android.playback

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class MixedQueuePersistenceTest {
    @Test fun deviceEnvelopeRestoresWithoutNumericServerIdentity() {
        val raw = """{"version":3,"endpoint":"fixture","account":"guest","selected":0,"position":2345,"items":[{"occurrence":"12345678-1234-1234-1234-123456789012","track":0,"title":"Phone recording","artist":"","manual":false,"localOnly":true,"durationMs":601000,"origin":"Context","ref":{"kind":"device","id":"12345678-1234-1234-1234-123456789013","sha256":"${"a".repeat(64)}","bytes":1234,"incarnation":1}}]}"""
        val restored = QueueSnapshot.decode(raw,"fixture","guest")
        assertNotNull("Typed device queue must survive restart without a fabricated TrackId",restored)
        assertEquals(2345L,restored!!.position)
        val root=Files.createTempDirectory("mixed-queue-").toFile()
        try {val store=QueueSnapshotStore(java.io.File(root,"queue.json"));store.write(restored);assertEquals(restored,store.read("fixture","guest"))} finally {root.deleteRecursively()}
    }
    @Test fun legacyServerObservationMigratesExplicitly() {
        val raw="""{"version":1,"endpoint":"fixture","account":"user","selected":0,"position":4,"items":[{"occurrence":"legacy","track":17,"title":"Server","artist":"","manual":true}]}"""
        val restored=QueueSnapshot.decode(raw,"fixture","user")!!
        assertEquals(17L,restored.items.single().track)
        assertTrue("Successor writes explicit mixed format",restored.encode().contains("\"version\":3"))
    }
}
