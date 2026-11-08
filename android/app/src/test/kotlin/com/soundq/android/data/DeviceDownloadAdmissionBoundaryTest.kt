package com.soundq.android.data

import com.soundq.android.data.offline.DeviceDownloads
import org.junit.Assert.*
import org.junit.Test
import java.io.File

import java.nio.file.Files

/** Admission failure must remain diagnosable without weakening file custody. */
class DeviceDownloadAdmissionBoundaryTest {
    @Test fun firstOwnedCanonicalDirectoryClaimIsWritable() {
        HttpsFixture().use { fixture ->
            val root=Files.createTempDirectory(File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"device-downloads-").toFile()
            try {
                val aliases=generateSequence(root.absoluteFile){it.parentFile}.filter {Files.isSymbolicLink(it.toPath())}.map {it.path}.toList()
                assertTrue("Test TMPDIR must not introduce symlink ancestors: $aliases",aliases.isEmpty())
                val session=AccountSession(fixture.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","A"))}
                val scope=session.capture()!!
                val store=DeviceDownloads(root,session,SoundQApi(session,fixture.client),fixture.client)
                store.load(scope)
                val claim=store.claim(scope,Track(TrackId(7),"Fixture")){true}

                assertFalse("Original owned scope must be writable",store.state.value.rejected)
                assertNotNull("Original owned first claim must be admitted",claim)
            }finally {root.deleteRecursively()}
        }
    }
}
