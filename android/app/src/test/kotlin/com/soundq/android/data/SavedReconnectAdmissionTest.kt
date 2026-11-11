package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test


class SavedReconnectAdmissionTest {
    @Test fun noSavedRecordCannotOfferOrDispatchReconnect() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());val api=SoundQApi(session,f.client)
            assertFalse(api.restore());assertFalse(session.canReconnectSaved());assertNull(session.claimSavedRestore())
            assertFalse(session.canListenOffline());assertEquals(0,f.server.requestCount)
        }
    }
    @Test fun decodedSavedRecordAllowsExplicitReconnectButNeverAutomaticReplayOfOfflineMode() {
        HttpsFixture().use {f ->
            val store=MemoryStore().apply {tokens=SecretTokens("old","old-r","A")};val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            assertFalse(session.restore {false});assertTrue(session.canReconnectSaved());assertTrue(session.canListenOffline())
            val ticket=session.claimSavedRestore()!!;assertNull(session.claimSavedRestore())
            f.reply(f.auth("A","rotated"));assertTrue(api.restoreOnline(ticket));assertFalse(api.restoreOnline(ticket));assertEquals(1,f.server.requestCount)
            assertFalse(session.canReconnectSaved());assertNull(session.claimSavedRestore())
            session.failure(session.version(),SafeFailure.Reason.Network,true);assertTrue(session.canReconnectSaved())
            assertTrue(session.useDeviceDownloads());assertFalse(session.canReconnectSaved());assertNull(session.claimSavedRestore());assertFalse(api.restore())
            assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun savedReconnectTicketCannotRebindAcrossLocalLockOrSameAccountReplacement() {
        HttpsFixture().use {f ->
            val store=MemoryStore().apply {tokens=SecretTokens("old","old-r","A")};val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            assertFalse(session.restore {false});val old=session.claimSavedRestore()!!
            assertTrue(session.accept(session.beginIntent(),SecretTokens("fresh","fresh-r","A")))
            session.failure(session.version(),SafeFailure.Reason.Network,true)
            assertFalse(api.restoreOnline(old));assertEquals(0,f.server.requestCount)
            f.reply(f.auth("A","rotated"));assertTrue(api.restoreOnline(session.claimSavedRestore()!!))
        }
    }
}
