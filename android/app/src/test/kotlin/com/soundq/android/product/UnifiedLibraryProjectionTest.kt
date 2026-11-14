package com.soundq.android.product

import com.soundq.android.data.*
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.playback.PlaybackRef
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class UnifiedLibraryProjectionTest {
    @Test fun sourceCorpusPreservesOverlapTypedIdentityAndAccountlessFence() {
        val p=file(1,"Phone");val r=file(2,"Revoked",false)
        val u=p.copy(id=DeviceFileId(UUID(0,3)),metadata=OriginalMetadata("protected.mp3","Unplayable"),aliases=p.aliases.map {it.copy(state=AccessState.UNSUPPORTED)})
        val s=Track(TrackId(1),"Stream");val d=Track(TrackId(2),"Download")
        val snapshot=DeviceListeningSnapshot(1,listOf(p,u,r),emptyList(),emptyList())
        fun rows(account:String?,remote:List<Track>,source:LibrarySource)=unifiedLibraryRows("e",account,remote,listOf(d),snapshot,LibraryQuery(),source,false)
        assertEquals(listOf("Stream","Download","Phone","Revoked","Unplayable"),rows("a",listOf(s,d),LibrarySource.All).map {it.title})
        assertEquals(listOf("Stream","Download"),rows("a",listOf(s,d),LibrarySource.Server).map {it.title})
        assertEquals(listOf("Download","Phone","Unplayable"),rows("a",listOf(s,d),LibrarySource.Local).map {it.title})
        // A DeviceOnly session supplies only its owned download, with no remote projection.
        assertEquals(listOf("Download"),rows("a",emptyList(),LibrarySource.Server).map {it.title})
        assertEquals(listOf("Phone","Revoked","Unplayable"),rows(null,listOf(s,d),LibrarySource.All).map {it.title})
        assertTrue(rows(null,listOf(s,d),LibrarySource.Server).isEmpty())
        assertEquals(listOf("Phone","Unplayable"),rows(null,emptyList(),LibrarySource.Local).map {it.title})
        for(source in LibrarySource.entries) {
            val result=rows("a",listOf(s,d),source)
            assertEquals(1,result.count {it.ref==PlaybackRef.Server("e","a",2)})
            assertEquals(result.size,result.map {it.stable}.distinct().size)
        }
        assertEquals(PlaybackRef.Device(p.id.value.toString(),p.revision.sha256,p.revision.byteLength,p.incarnation),rows(null,emptyList(),LibrarySource.Local).first().ref)
        assertEquals(listOf(p,u,r),snapshot.files) // projection never rewrites originals/availability
    }

    @Test fun sourceComposesWithQueryCollectionSortDirectionAndRecency() {
        val p=file(1,"Phone");val other=file(2,"Other").copy(metadata=OriginalMetadata("other.wav","Other","Else","Else"))
        val d=Track(TrackId(1),"Download","Artist","Album",1000,liked=true)
        val s=Track(TrackId(2),"Stream","Else","Else",2000)
        val snapshot=DeviceListeningSnapshot(1,listOf(p,other),emptyList(),listOf(ListeningHistory(HistoryKey.Device(p.id),200,null),ListeningHistory(HistoryKey.Server(ServerAccount("e","a"),ServerAudioId(1)),100,null)))
        fun rows(source:LibrarySource,query:LibraryQuery=LibraryQuery(),recent:Boolean=false)=unifiedLibraryRows("e","a",listOf(d,s),listOf(d),snapshot,query,source,recent)
        for(source in LibrarySource.entries) {
            val collection=rows(source,LibraryQuery(collection=LibraryCollection("Artist","Album")))
            assertEquals(if(source==LibrarySource.Server)listOf("Download")else listOf("Download","Phone"),collection.map {it.title})
            assertEquals(listOf("Download"),rows(source,LibraryQuery(liked=true)).map {it.title})
            for(query in listOf(LibraryQuery(verified=true),LibraryQuery(verified=false),LibraryQuery(genre="House")))
                assertTrue(rows(source,query).all {it.ref is PlaybackRef.Server})
            // An acknowledged server search match is not reinterpreted using display text.
            assertEquals(if(source==LibrarySource.Local)listOf("Download","Phone")else if(source==LibrarySource.Server)listOf("Download","Stream")else listOf("Download","Stream","Phone"),rows(source,LibraryQuery(text="phone")).map {it.title})
            for(sort in listOf(LibrarySort.Title,LibrarySort.Artist,LibrarySort.Duration)) {
                val asc=rows(source,LibraryQuery(sort=sort,ascending=true))
                val desc=rows(source,LibraryQuery(sort=sort,ascending=false))
                assertEquals(asc.map {it.ref}.toSet(),desc.map {it.ref}.toSet())
                when(sort) {
                    LibrarySort.Title->{assertEquals(asc.map {it.title}.sorted(),asc.map {it.title});assertEquals(asc.map {it.title}.reversed(),desc.map {it.title})}
                    LibrarySort.Artist->{assertEquals(asc.map {it.artist}.sorted(),asc.map {it.artist});assertEquals(asc.map {it.artist}.reversed(),desc.map {it.artist})}
                    else->{assertEquals(asc.map {it.durationMs}.sorted(),asc.map {it.durationMs});assertEquals(asc.map {it.durationMs}.reversed(),desc.map {it.durationMs})}
                }
            }
            val recent=rows(source,recent=true)
            assertEquals(if(source==LibrarySource.Server)"Download"else "Phone",recent.first().title)
        }
        assertEquals(listOf("Other","Phone","Stream","Download"),rows(LibrarySource.All,LibraryQuery(sort=LibrarySort.Duration,ascending=false)).map {it.title})
        assertTrue(rows(LibrarySource.Server,LibraryQuery(collection=LibraryCollection("Missing"))).isEmpty())
    }

    @Test fun serverSearchMatchesSurviveOverridesAndMultiwordDisplayFields() {
        val overridden=Track(TrackId(1),"Custom title",artist="Custom artist")
        val multiword=Track(TrackId(2),"Blue",artist="Miles")
        val download=Track(TrackId(3),"Unrelated")
        for(query in listOf("Canonical recording","Blue Miles")) {
            val rows=unifiedLibraryRows("e","a",listOf(overridden,multiword),listOf(overridden,download),null,LibraryQuery(text=query),LibrarySource.All,false)
            assertEquals(listOf(1L,2L),rows.map {(it.ref as PlaybackRef.Server).id})
        }
    }
    private fun file(id:Int,title:String,available:Boolean=true)=DeviceAudio(DeviceFileId(UUID(0,id.toLong())),ProviderObjectId("fixture","$id"),ContentRevision("a".repeat(64),40),1,OriginalMetadata("$id.wav",title,"Artist","Album"),601000,listOf(LocatorAccess(ScanGrantId(UUID(1,id.toLong())),ProviderLocator("fixture","$id"),if(available)AccessState.AVAILABLE else AccessState.REVOKED)))
    @Test fun inclusiveLocalAndSubmittedQueryRetainTypedSourcesAndPersistedRecencyTies() {
        val phone=file(1,"Beta");val unavailable=file(2,"Unavailable",false)
        val server=Track(TrackId(1),"Alpha");val remote=Track(TrackId(2),"Remote")
        val snapshot=DeviceListeningSnapshot(1,listOf(phone,unavailable),emptyList(),listOf(ListeningHistory(HistoryKey.Device(phone.id),100,null),ListeningHistory(HistoryKey.Server(ServerAccount("endpoint","owner"),ServerAudioId(1)),100,null)))
        val all=unifiedLibraryRows("endpoint","owner",listOf(server,remote),listOf(server),snapshot,LibraryQuery(),LibrarySource.All,true)
        assertEquals(listOf("Alpha","Beta","Remote","Unavailable"),all.map {it.title})
        assertTrue(all[0].ref is PlaybackRef.Server);assertTrue(all[1].ref is PlaybackRef.Device)
        val local=unifiedLibraryRows("endpoint","owner",listOf(server,remote),listOf(server),snapshot,LibraryQuery(),LibrarySource.Local,true)
        assertEquals(listOf("Alpha","Beta"),local.map {it.title})
        assertEquals(listOf("Beta"),unifiedLibraryRows("endpoint",null,emptyList(),emptyList(),snapshot,LibraryQuery(text="beta"),LibrarySource.Local,true).map {it.title})
        assertEquals(2,unifiedLibraryRows("endpoint",null,emptyList(),emptyList(),snapshot,LibraryQuery(),LibrarySource.All,true).size)
    }
    private fun phone(id:Int,title:String,vararg states:Pair<ScanGrantId,AccessState>)=DeviceAudio(DeviceFileId(UUID(0,id.toLong())),ProviderObjectId("fixture","$id"),ContentRevision("a".repeat(64),40),1,
        OriginalMetadata("$id.mp3",title),null,states.map {(grant,state)->LocatorAccess(grant,ProviderLocator("fixture","$id"),state)})
    @Test fun undecodablePhoneFileStaysVisibleInLocalFilesAsUnplayable() {
        val indexed=ScanGrant(ScanGrantId(UUID(2,1)),GrantKind.INDEXED,"Android audio index",ProviderLocator("android","indexed:external-audio"),false,AccessState.REVOKED)
        val undecodable=phone(1,"Encrypted",indexed.id to AccessState.UNREADABLE)
        val unsupported=phone(2,"Protected",indexed.id to AccessState.UNSUPPORTED)
        val revoked=phone(3,"Revoked",indexed.id to AccessState.REVOKED)
        val missing=phone(4,"Deleted",indexed.id to AccessState.MISSING)
        val snapshot=DeviceListeningSnapshot(1,listOf(undecodable,unsupported,revoked,missing),listOf(indexed),emptyList())
        // A file that is present but cannot be decoded must not silently vanish from Local files after a failed tap.
        assertEquals(listOf("Encrypted","Protected"),unifiedLibraryRows("e",null,emptyList(),emptyList(),snapshot,LibraryQuery(),LibrarySource.Local,false).map {it.title}.sorted())
        assertEquals("Can’t play this file",phoneRowUnavailableLabel(undecodable))
        assertEquals("Can’t play this file",phoneRowUnavailableLabel(unsupported))
        assertEquals("Unavailable · File access is off",phoneRowUnavailableLabel(revoked))
        // All files access is the only route: no row asks for a file to be chosen again.
        assertEquals("Unavailable",phoneRowUnavailableLabel(missing))
    }
    @Test fun downloadsNeverDuplicateAcknowledgedServerIdentityAndPhoneCannotBecomeLiked() {
        val track=Track(TrackId(1),"Same",liked=true);val phone=file(1,"Same")
        val snapshot=DeviceListeningSnapshot(1,listOf(phone),emptyList(),emptyList())
        assertEquals(2,unifiedLibraryRows("e","a",listOf(track),listOf(track),snapshot,LibraryQuery(),LibrarySource.Local,false).size)
        assertEquals(1,unifiedLibraryRows("e","a",listOf(track),listOf(track),snapshot,LibraryQuery(liked=true),LibrarySource.All,false).size)
        assertTrue(unifiedLibraryRows("e",null,emptyList(),listOf(track),snapshot,LibraryQuery(),LibrarySource.Local,false).single().ref is PlaybackRef.Device)
    }
}
