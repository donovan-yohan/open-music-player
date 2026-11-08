package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class TimelineApiTest {
    @Test fun realAnalysisUsesAuthenticatedExistingRouteAndRetiredRouteCannotDispatch() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("synthetic-a","synthetic-r","fixture"))
            val api=SoundQApi(session,f.client);val scope=session.capture()!!
            f.reply("""{"track_id":7,"schema_version":1,"status":"completed","updated_at":"v1","summary":{"waveform":{"peaks":[0.2,0.8]}}}""")
            assertEquals(2,api.analysisWaveform(scope,TrackId(7),1000).tiers.single().minima.size)
            val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("GET",request.method);assertEquals("/api/v1/tracks/7/analysis",request.url.encodedPath)
            assertEquals("Bearer synthetic-a",request.headers["Authorization"])
            assertThrows(SafeFailure::class.java){api.analysisWaveform(scope,TrackId(7),1000){false}}
            assertNull(f.server.takeRequest(100,TimeUnit.MILLISECONDS))
        }
    }
}
