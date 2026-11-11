package com.soundq.android.data

import com.soundq.android.data.offline.*
import mockwebserver3.MockResponse
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class DeviceDownloadCleanupCustodyTest {
    private class Fixture : AutoCloseable {
        val tls = HttpsFixture()
        val root = Files.createTempDirectory(File(System.getenv("TMPDIR")!!).toPath(), "download-custody-").toFile()
        val session = playlistSession(tls)
        val scope = session.capture()!!
        val store = DeviceDownloads(root, session, SoundQApi(session, tls.client), tls.client).also { it.load(scope) }
        val track = Track(TrackId(7), "Custody fixture")
        val payload = ByteArray(128) { it.toByte() }
        fun transfer() {
            tls.reply("""{"urls":[{"trackId":7,"url":"${tls.server.url("/media/copy.wav")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/wav","sizeBytes":128}]}""")
            tls.server.enqueue(MockResponse.Builder().body(Buffer().write(payload)).build())
            store.transfer(store.claim(scope, track) { true }!!)
            assertEquals(2, tls.server.requestCount)
        }
        fun stage() = root.walkTopDown().single { it.name.startsWith("transfer-") && it.extension == "part" }
        override fun close() { tls.close(); root.deleteRecursively() }
    }

    @Test fun ordinaryReplacementDirectoryForeignStageSurvivesRefusedPromotionCleanup() {
        replacementDirectory(copyIndex = false)
    }

    @Test fun byteIdenticalIndexDoesNotGrantCustodyOfReplacementDirectoryStage() {
        replacementDirectory(copyIndex = true)
    }

    private fun replacementDirectory(copyIndex: Boolean) {
        Fixture().use { f ->
            var sentinel: File? = null
            var originalStage: File? = null
            f.store.beforePromotion = {
                val stage = f.stage()
                val directory = stage.parentFile!!
                val index = File(directory, "index.v1.json").readBytes()
                val held = File(f.root, "retained-original-scope")
                check(directory.renameTo(held)); check(directory.mkdir())
                originalStage = File(held, stage.name)
                sentinel = File(directory, stage.name).apply { writeText("foreign replacement sentinel") }
                if (copyIndex) File(directory, "index.v1.json").writeBytes(index)
            }
            f.transfer()
            assertNotNull(sentinel)
            assertTrue("Foreign same-name stage must not be deleted", sentinel!!.isFile)
            assertEquals("foreign replacement sentinel", sentinel!!.readText())
            assertArrayEquals(f.payload, originalStage!!.readBytes())
            assertFalse(f.store.state.value.rows.any { it.status == DownloadStatus.Complete })
            assertNull(f.store.acquire(f.scope, f.track.id))
        }
    }

    @Test fun replacementFileInsideOriginalDirectoryIsNotDeletedOrPromoted() {
        Fixture().use { f ->
            var sentinel: File? = null
            var held: File? = null
            f.store.beforePromotion = {
                val stage = f.stage()
                held = File(stage.parentFile, "retained-original-stage")
                check(stage.renameTo(held))
                sentinel = File(stage.path).apply { writeBytes(f.payload) }
                // Explicit cancellation takes cleanup without hashing/promoting the replacement.
                assertTrue(f.store.cancel(f.scope, f.store.state.value.rows.single()))
            }
            f.transfer()
            assertTrue("Foreign same-byte replacement inode must survive", sentinel!!.isFile)
            assertArrayEquals(f.payload, sentinel!!.readBytes())
            assertArrayEquals(f.payload, held!!.readBytes())
            assertEquals(DownloadStatus.Cancelled, f.store.state.value.rows.single().status)
        }
    }

    @Test fun ordinaryCancellationStillRemovesItsOwnStageAndKeepsForeignSibling() {
        Fixture().use { f ->
            var stage: File? = null
            var sibling: File? = null
            f.store.beforePromotion = {
                stage = f.stage()
                sibling = File(stage!!.parentFile, "foreign-sibling.part").apply { writeText("keep sibling") }
                assertTrue(f.store.cancel(f.scope, f.store.state.value.rows.single()))
            }
            f.transfer()
            assertFalse("Original owned stage is still cleaned", stage!!.exists())
            assertEquals("keep sibling", sibling!!.readText())
            assertEquals(DownloadStatus.Cancelled, f.store.state.value.rows.single().status)
        }
    }

    @Test fun sameByteReplacementCannotBePromotedWithoutItsOriginalFileIncarnation() {
        Fixture().use { f ->
            var replacement: File? = null
            var held: File? = null
            f.store.beforePromotion = {
                val stage = f.stage()
                held = File(stage.parentFile, "retained-owned-stage")
                check(stage.renameTo(held))
                replacement = File(stage.path).apply { writeBytes(f.payload) }
            }
            f.transfer()
            assertTrue("Replacement stage is preserved rather than adopted", replacement!!.isFile)
            assertArrayEquals(f.payload, replacement!!.readBytes())
            assertArrayEquals(f.payload, held!!.readBytes())
            assertFalse(f.store.state.value.rows.any { it.status == DownloadStatus.Complete })
            assertNull(f.store.acquire(f.scope, f.track.id))
        }
    }

    @Test fun ordinaryPromotionKeepsExactArtifactAndNoTemporaryStages() {
        Fixture().use { f ->
            f.transfer()
            assertEquals(DownloadStatus.Complete, f.store.state.value.rows.single().status)
            assertFalse(f.root.walkTopDown().any { it.extension in listOf("part", "new") })
            val actual = ByteArray(128)
            f.store.acquire(f.scope, f.track.id)!!.use { lease -> assertEquals(128, lease.read(actual, 0, actual.size)) }
            assertArrayEquals(f.payload, actual)
        }
    }
}
