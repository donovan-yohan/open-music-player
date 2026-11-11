package com.soundq.android.data

import com.soundq.android.data.trackdetails.*
import com.soundq.android.playback.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class PlayerTrackDetailsTest {
    // Execute the new production entry if present. Its absence is an unavailable
    // player action, not a missing-symbol compiler failure on the predecessor.
    private fun openPlayer(repository:TrackDetailsRepository,scope:AccountScope,p:PlaybackProjection,latest:()->PlaybackProjection):DetailsRoute? {
        val method=repository.javaClass.methods.singleOrNull {it.name=="capturePlayer"} ?: return null
        val capture=method.invoke(repository,scope,p,latest) ?: return null
        return repository.javaClass.methods.single {it.name=="open"&&it.parameterTypes.single()==capture.javaClass}.invoke(repository,capture) as DetailsRoute?
    }
    private fun playing(scope:AccountScope)=PlaybackProjection(connection=PlaybackProjection.Connection.Connected,title="Queued original",queue=listOf(QueueOccurrence("occ-7",7,"Queued original","Ensemble",false)),selectedOccurrence="occ-7",positionMs=3200,isPlaying=true,accountEpoch=scope.epoch,sessionIdentity="service-session",sourceQueueIncarnation="queue-1")

    @Test fun retiredSelectionIncarnationRefusesStaleRenderedOpenAndClaimAfterSameOccurrenceReturns() {
        HttpsFixture().use {f->
            val (api,_,repository)=detailsSetup(f);val scope=api.session.capture()!!
            val original=playing(scope);var latest=original
            val capture=repository.capturePlayer(scope,original){latest}!!
            val route=repository.open(capture)!!
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val observed=repository.state.value.detail!!
            latest=original.copy(selectionIncarnation=original.selectionIncarnation+2)
            assertNull("A-B-A must not revive a retained rendered Info callback",repository.open(capture))
            assertNull(repository.claim(route,observed,DetailsAction.Metadata(MetadataDraft("Wrong"))))
            assertEquals(2,f.server.requestCount)
        }
    }

    @Test fun missingMembershipAndFailedMembershipReadNeverGrantMetadataWrites() {
        for(missing in listOf(true,false))HttpsFixture().use {f->
            val (api,_,repository)=detailsSetup(f);val scope=api.session.capture()!!;val p=playing(scope)
            val route=repository.open(repository.capturePlayer(scope,p){p}!!)!!
            f.reply(if(missing)detailsPage(null) else "{}",if(missing)200 else 503);repository.load(route)
            assertNull(repository.state.value.detail)
            assertEquals(missing,repository.state.value.missing)
            assertEquals(1,f.server.requestCount)
            if(!missing){assertNotNull(repository.state.value.error);f.reply(detailsPage());f.reply("{}",404);repository.load(route);assertNotNull(repository.state.value.detail)}
        }
    }
    @Test fun invalidOrAmbiguousPlayerSourcesCannotReadRemoteDetails() {
        HttpsFixture().use {f->
            val (api,_,repository)=detailsSetup(f);val scope=api.session.capture()!!;val p=playing(scope)
            val invalid=listOf(p.copy(connection=PlaybackProjection.Connection.Disconnected),p.copy(localOnly=true),p.copy(source=PlaybackSource.Arrangement),p.copy(source=PlaybackSource.SavedMix),p.copy(accountEpoch=scope.epoch-1),p.copy(queue=emptyList()),p.copy(queue=p.queue+p.queue),p.copy(queue=listOf(p.queue.single().copy(trackId=0))),p.copy(sessionIdentity="redacted"),p.copy(sourceQueueIncarnation=""))
            invalid.forEach {assertNull(repository.capturePlayer(scope,it){it})}
            assertEquals(0,f.server.requestCount)
        }
    }
    @Test fun harmlessTicksPauseAndReorderKeepAdmittedRouteAndLibraryEntryStaysAdmissionOnly() {
        HttpsFixture().use {f->
            val (api,library,repository)=detailsSetup(f);val scope=api.session.capture()!!;val p=playing(scope);var latest=p
            val route=repository.open(repository.capturePlayer(scope,p){latest}!!)!!
            latest=p.copy(positionMs=9999,isPlaying=false,queue=(p.queue+QueueOccurrence("other",8,"Other","",false)).reversed(),queueRevision=5)
            assertTrue(repository.current(route))
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            assertNotNull(repository.claim(route,repository.state.value.detail!!,DetailsAction.Metadata(MetadataDraft("Accepted"))))
            repository.close(route)
            val libraryRoute=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            library.refine(LibraryQuery(text="different"));assertTrue(repository.current(libraryRoute))
            f.reply(detailsPage());f.reply("{}",404);repository.load(libraryRoute)
            assertNotNull(repository.claim(libraryRoute,repository.state.value.detail!!,DetailsAction.Metadata(MetadataDraft("Still admitted"))))
        }
    }
    @Test fun heldLoadCannotPublishAfterCloseSelectionServiceQueueAccountOrSameAccountRelogin() {
        for(change in 0..6)HttpsFixture().use {f->
            val (api,_,repository)=detailsSetup(f);val scope=api.session.capture()!!;val p=playing(scope);var latest=p
            val route=repository.open(repository.capturePlayer(scope,p){latest}!!)!!
            val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1);val pool=java.util.concurrent.Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                entered.countDown();check(release.await(5,TimeUnit.SECONDS));return mockwebserver3.MockResponse.Builder().body(detailsPage()).build()
            }}
            try {
                val task=pool.submit {repository.load(route)};assertTrue(entered.await(3,TimeUnit.SECONDS))
                when(change){0->repository.close(route);1->latest=p.copy(selectedOccurrence="other");2->latest=p.copy(selectionIncarnation=p.selectionIncarnation+2);3->latest=p.copy(sessionIdentity="replacement");4->latest=p.copy(sourceQueueIncarnation="replacement");5,6->api.session.accept(api.session.beginIntent(),SecretTokens("a","r",if(change==5)"other" else scope.accountId))}
                release.countDown();task.get(5,TimeUnit.SECONDS)
                assertNull(repository.state.value.detail);assertFalse(repository.current(route));assertEquals(1,f.server.requestCount)
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun heldClaimCannotDispatchAfterCloseSelectionAccountOrSameAccountRelogin() {
        for(change in 0..4)HttpsFixture().use {f->
            val (api,_,repository)=detailsSetup(f);val scope=api.session.capture()!!;val p=playing(scope);var latest=p
            val route=repository.open(repository.capturePlayer(scope,p){latest}!!)!!
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val observed=repository.state.value.detail!!
            val action=DetailsAction.Metadata(MetadataDraft("Wrong"));val ticket=repository.claim(route,observed,action)!!
            when(change){0->repository.close(route);1->latest=p.copy(selectedOccurrence="other");2->latest=p.copy(selectionIncarnation=p.selectionIncarnation+2);3,4->api.session.accept(api.session.beginIntent(),SecretTokens("a","r",if(change==3)"other" else scope.accountId))}
            assertNull(repository.claim(route,observed,action));repository.execute(ticket);assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun heldWriteAfterRetirementCannotReadbackPublishOrReplay() {
        HttpsFixture().use {f->
            val (api,_,repository)=detailsSetup(f);val scope=api.session.capture()!!;val p=playing(scope);var latest=p
            val route=repository.open(repository.capturePlayer(scope,p){latest}!!)!!
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val observed=repository.state.value.detail!!
            val ticket=repository.claim(route,observed,DetailsAction.Metadata(MetadataDraft("Sent")))!!
            val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1);val pool=java.util.concurrent.Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                entered.countDown();check(release.await(5,TimeUnit.SECONDS));return mockwebserver3.MockResponse.Builder().body("""{"track_id":7,"has_metadata_override":true,"title":"Sent","artist":null,"album":null}""").build()
            }}
            try {
                val task=pool.submit {repository.execute(ticket)};assertTrue(entered.await(3,TimeUnit.SECONDS))
                latest=p.copy(selectionIncarnation=p.selectionIncarnation+2);release.countDown();task.get(5,TimeUnit.SECONDS);repository.execute(ticket)
                assertSame(observed,repository.state.value.detail);assertEquals(3,f.server.requestCount);assertFalse(repository.current(route))
            } finally {release.countDown();pool.shutdownNow()}
        }
    }

    @Test fun offPageMembershipUsesCanonicalUnfilteredPaginationWithoutLoadingLibraryRows() {
        HttpsFixture().use {f->
            val (api,library,repository)=detailsSetup(f);val scope=api.session.capture()!!;val p=playing(scope)
            library.refine(LibraryQuery(text="hide-current",liked=true));val before=library.state.value
            val route=repository.open(repository.capturePlayer(scope,p){p}!!)!!
            f.reply("""{"tracks":[{"id":8,"title":"Other","artist":"Ensemble","has_metadata_override":false,"mb_verified":false}],"total":2,"limit":100,"offset":0}""")
            f.reply("""{"tracks":[${detailsRow()}],"total":2,"limit":100,"offset":1}""");f.reply("{}",404)
            repository.load(route);assertEquals(TrackId(7),repository.state.value.detail!!.track.id)
            assertSame(before,library.state.value)
            val requests=(1..3).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!}
            assertEquals(listOf("0","1"),requests.take(2).map {it.url.queryParameter("offset")})
            requests.take(2).forEach {assertNull(it.url.queryParameter("q"));assertNull(it.url.queryParameter("liked"))}
        }
    }

    @Test fun filteredPlayingOwnedSongUsesCanonicalMembershipPutAndExactReadbackWithoutChangingLibraryOrPlayback() {
        HttpsFixture().use {f->
            val api=SoundQApi(playlistSession(f),f.client)
            val hidden=Track(TrackId(8),"Visible other song")
            val library=LibraryRepository(api.session,{_,_,_->LibraryPage(listOf(hidden),1,20,0)},{_,_,_->error("No Like write")})
            library.refine(LibraryQuery(text="Visible",liked=true,genre="Jazz"))
            val before=library.state.value;val scope=api.session.capture()!!;val p=playing(scope)
            val repository=TrackDetailsRepository(api,library)
            val route=openPlayer(repository,scope,p){p}
            assertNotNull("Now playing must admit an ordinary remote song without a visible Library row",route)
            assertNull(repository.state.value.detail)
            f.reply(detailsPage());f.reply("{}",404);repository.load(route!!)
            val ticket=repository.claim(route,repository.state.value.detail!!,DetailsAction.Metadata(MetadataDraft("Personal title")))!!
            f.reply("""{"track_id":7,"has_metadata_override":true,"title":"Personal title","artist":null,"album":null}""")
            f.reply(detailsPage(detailsRow("Personal title",true)));repository.execute(ticket);repository.execute(ticket)
            assertEquals("Personal title",repository.state.value.detail!!.track.title)
            assertEquals(MutationOutcome.Confirmed,repository.state.value.outcome)
            assertEquals(before.query,library.state.value.query)
            assertEquals(before.rows,library.state.value.rows)
            assertEquals(p,playing(scope))
            assertEquals("Queued original",p.queue.single().title)
            assertEquals(3200L,p.positionMs);assertTrue(p.isPlaying)
            val requests=(1..4).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!}
            assertEquals(listOf("GET","GET","PUT","GET"),requests.map {it.method})
            assertEquals("/api/v1/tracks/7/metadata-override",requests[2].url.encodedPath)
            assertEquals("""{"title":"Personal title","artist":null,"album":null}""",requests[2].body!!.utf8())
            assertEquals("/api/v1/library",requests[0].url.encodedPath)
            assertNull(requests[0].url.queryParameter("search"))
            assertEquals(4,f.server.requestCount)
        }
    }
}
