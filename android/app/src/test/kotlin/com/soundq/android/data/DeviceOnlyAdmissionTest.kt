package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test

class DeviceOnlyAdmissionTest {
    @Test fun deviceChoiceAtActualTlsDispatchBoundaryPreventsRefreshEgress() {
        HttpsFixture().use {f ->
            val store=MemoryStore().apply {tokens=SecretTokens("a","r","A")};val session=AccountSession(f.endpoint,store)
            var intercepted=false
            val client=f.client.newBuilder().addInterceptor {chain ->
                intercepted=true;assertTrue(session.useDeviceDownloads());chain.proceed(chain.request())
            }.build()
            try {
                assertFalse(SoundQApi(session,client).restore());assertTrue(intercepted)
                assertEquals("DeviceOnly",session.state.value.javaClass.simpleName)
                assertEquals(0,f.server.requestCount);assertEquals(0,store.writes)
                assertTrue(runCatching {session.access(session.capture()!!)}.isFailure)
            } finally {client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()}
        }
    }

    @Test fun onlyUnconsumedDeviceAdmissionCanLoadAndConsumedSaveCannotBeBypassed() {
        HttpsFixture().use {f ->
            val store=MemoryStore().apply {tokens=SecretTokens("a","r","A")};val session=AccountSession(f.endpoint,store)
            val intent=session.claimDeviceDownloads()!!
            assertTrue(session.accept(intent,SecretTokens("b","br","B")))
            assertFalse("delayed local load cannot replace accepted online identity",session.loadDeviceDownloads(intent))
            assertEquals(AuthState.SignedIn("B"),session.state.value)
            val failing=MemoryStore().apply {tokens=SecretTokens("old","old-r","A");fail=true}
            val waiting=AccountSession(f.endpoint,failing)
            waiting.restore {scope ->
                assertFalse(waiting.refresh(scope){SecretTokens("rotated","rotated-r","A")})
                assertTrue(waiting.state.value is AuthState.SaveRequired)
                assertFalse("active restore must not let local entry bypass secure save failure",waiting.useDeviceDownloads())
                false
            }
            assertTrue(waiting.state.value is AuthState.SaveRequired);assertNull(waiting.capture());assertEquals(0,f.server.requestCount)
        }
    }
}
