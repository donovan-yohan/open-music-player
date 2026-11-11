package com.soundq.android.data

import com.soundq.android.data.imports.*
import com.soundq.android.data.playlists.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** The actual import-owned reader must publish a row eligible for the actual membership owner. */
class ImportedMembershipCompositionTest {
    @Test fun explicitImportedRowCanAddWithoutLosingFilterOrReplayingImport() {
        HttpsFixture().use { f ->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val api=SoundQApi(session,f.client)
            val library=LibraryRepository(session,api::library,api::like)
            val imports=ImportRepository(session,api,library)
            val requests=CopyOnWriteArrayList<String>()
            val jobId="123e4567-e89b-12d3-a456-426614174001"
            val summary="""{"id":41,"name":"海辺 — Étude","isPublic":false,"trackCount":1,"durationMs":0}"""
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                val path=request.url.encodedPath
                requests.add(request.method+" "+path)
                val body=when {
                    path=="/api/v1/downloads"->"""{"jobs":[{"job_id":"$jobId","status":"complete","progress":100,"track_id":82,"source_type":"youtube","created_at":"2026-10-28T00:00:00Z"}]}"""
                    path=="/api/v1/library"->"""{"tracks":[{"id":82,"title":"Imported row","is_liked":false}],"total":1,"limit":20,"offset":0}"""
                    path=="/api/v1/playlists/41/tracks"->"""{"added":[82],"skipped":[],"playlist":$summary}"""
                    path=="/api/v1/playlists/41"->summary.dropLast(1)+""", "tracks":[{"id":82,"title":"Imported row"}]}"""
                    path=="/api/v1/playlists"->"""{"data":[$summary],"total":1,"limit":20,"offset":0}"""
                    else->error("unexpected fixture path")
                }
                return MockResponse.Builder().body(body).build()
            }}
            val view=imports.open()!!
            imports.recent(view);imports.select(view,imports.state.value.recent.single())
            assertTrue(imports.openLibrary(view))
            imports.close(view)
            val row=library.state.value.rows.single()
            val source=library.captureTrack(row)!!
            val owner=PlaylistMembershipRepository(api,library)
            val queue=ArrayDeque<()->Unit>()
            val actions=LibraryPlaylistActions(owner){queue.add(it)}
            val picker=actions.open(source)!!
            fun drain(){while(queue.isNotEmpty())queue.removeFirst().invoke()}
            picker.reload();drain()
            val before=library.state.value
            picker.submit(picker.select(owner.state.value.rows.single())!!);drain()
            assertEquals(MutationOutcome.Confirmed,owner.state.value.outcome)
            assertEquals(listOf(TrackId(82)),owner.state.value.ack!!.added)
            assertSame(before,library.state.value)
            assertEquals(listOf("POST /api/v1/playlists/41/tracks"),requests.filter {it.startsWith("POST")})
            assertEquals(6,requests.size)
            assertNotNull(library.captureTrack(row))
            library.refine(LibraryQuery(text="different query"))
            assertNull(actions.open(source))
            assertEquals(1,requests.count {it.startsWith("POST")})
            picker.close();actions.close()
        }
    }
}
