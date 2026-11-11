package com.soundq.android.data

import com.soundq.android.data.catalog.CatalogRepository
import com.soundq.android.data.playlists.*
import org.junit.Assert.*
import org.junit.Test

class IntegratedRemoteAdmissionTest {
    @Test fun deviceIdentityNeverGrantsCatalogOrPlaylistOrderSaveRouteCapabilities() {
        HttpsFixture().use { f ->
            val store=MemoryStore().apply {tokens=SecretTokens("synthetic-a","synthetic-r","local-account")}
            val session=AccountSession(f.endpoint,store)
            assertTrue(session.useDeviceDownloads())
            val local=session.capture()!!
            assertTrue(session.current(local));assertFalse(session.remoteCurrent(local))
            val api=SoundQApi(session,f.client)
            val catalog=CatalogRepository(api)
            assertNull("device-only identity must not grant a remote catalog visit",catalog.open())
            assertNull("device-only identity must not grant a member-order route",PlaylistOrderRepository(api,PlaylistDetailRepository(api)).enter())
            assertNull("device-only identity must not grant queue-save mutations",QueuePlaylistRepository(api).enter())
            assertEquals(0,f.server.requestCount)
            assertTrue(session.current(local))
        }
    }
}
