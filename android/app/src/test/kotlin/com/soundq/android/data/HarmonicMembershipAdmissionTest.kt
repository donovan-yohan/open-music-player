package com.soundq.android.data

import com.soundq.android.data.playlists.*
import org.junit.Assert.*
import org.junit.Test

class HarmonicMembershipAdmissionTest {
    @Test fun retainedFeatureAdmissionIsRecheckedBeforeSharedMembershipDispatchAndNeverReplayed() {
        HttpsFixture().use {f->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail());detail.open(PlaylistId(41))
            val manager=PlaylistManagementRepository(api,detail);val actions=PlaylistManagementActions(manager){it()}
            var current=true
            val work=manager.addHarmonic(actions.capture()!!,TrackId(11)){current}!!
            current=false;work()
            assertEquals(MutationOutcome.Refused,manager.state.value.outcome)
            assertEquals(1,f.server.requestCount)
            current=true;work();assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun sharedAdmissionConfirmsOnlyAfterExactAddedOrSkippedAckAndAcceptedMembershipReadback() {
        HttpsFixture().use {f->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail());detail.open(PlaylistId(41))
            val manager=PlaylistManagementRepository(api,detail);val actions=PlaylistManagementActions(manager){it()}
            val before=detail.state.value.detail
            val work=manager.addHarmonic(actions.capture()!!,TrackId(11)){true}!!
            assertNull(actions.capture());assertEquals(MutationOutcome.Pending,manager.state.value.outcome)
            f.reply("""{"added":[11],"skipped":[],"playlist":${managementSummary(ids=listOf(9,7,11))}}""")
            f.reply(managementDetail(ids=listOf(9,7,11)));work()
            assertEquals(MutationOutcome.Confirmed,manager.state.value.outcome)
            assertEquals(listOf(TrackId(11)),manager.state.value.ack!!.added)
            assertNotSame(before,detail.state.value.detail)
            val target=actions.capture()!!
            f.reply("""{"added":[],"skipped":[11],"playlist":${managementSummary(ids=listOf(9,7,11))}}""")
            f.reply(managementDetail(ids=listOf(9,7,11)));manager.addHarmonic(target,TrackId(11)){true}!!()
            assertEquals(listOf(TrackId(11)),manager.state.value.ack!!.skipped)
        }
    }
    @Test fun uncertaintySurvivesRouteReentryAndOnlyExistingGetRecoveryCanReleaseAdmission() {
        HttpsFixture().use {f->
            val api=SoundQApi(playlistSession(f),f.client);val detail=PlaylistDetailRepository(api)
            f.reply(managementDetail());detail.open(PlaylistId(41))
            val manager=PlaylistManagementRepository(api,detail);val actions=PlaylistManagementActions(manager){it()}
            val target=actions.capture()!!
            f.reply("{}",503);manager.addHarmonic(target,TrackId(11)){true}!!()
            assertEquals(MutationOutcome.Uncertain,manager.state.value.outcome)
            assertNull(manager.addHarmonic(target,TrackId(11)){true});actions.close()
            val reopened=PlaylistManagementActions(manager){it()};assertNull(reopened.capture())
            f.reply(managementDetail(ids=listOf(9,7,11)));reopened.recover()
            assertTrue(manager.state.value.reconciled);assertNotNull(reopened.capture())
            assertEquals(3,f.server.requestCount)
        }
    }
}
