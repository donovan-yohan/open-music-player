package com.soundq.android.product

import com.soundq.android.data.*
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.playback.PlaybackRef
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class UnifiedLibraryProjectionTest {
    @Test fun serverSearchMatchesSurviveOverridesAndMultiwordDisplayFields() {
        val overridden=Track(TrackId(1),"Custom title",artist="Custom artist")
        val multiword=Track(TrackId(2),"Blue",artist="Miles")
        val download=Track(TrackId(3),"Unrelated")
        for(query in listOf("Canonical recording","Blue Miles")) {
            val rows=unifiedLibraryRows("e","a",listOf(overridden,multiword),listOf(overridden,download),null,LibraryQuery(text=query),false,false)
            assertEquals(listOf(1L,2L),rows.map {(it.ref as PlaybackRef.Server).id})
        }
    }
    private fun file(id:Int,title:String,available:Boolean=true)=DeviceAudio(DeviceFileId(UUID(0,id.toLong())),ProviderObjectId("fixture","$id"),ContentRevision("a".repeat(64),40),1,OriginalMetadata("$id.wav",title,"Artist","Album"),601000,listOf(LocatorAccess(ScanGrantId(UUID(1,id.toLong())),ProviderLocator("fixture","$id"),if(available)AccessState.AVAILABLE else AccessState.REVOKED)))
    @Test fun inclusiveLocalAndSubmittedQueryRetainTypedSourcesAndPersistedRecencyTies() {
        val phone=file(1,"Beta");val unavailable=file(2,"Unavailable",false)
        val server=Track(TrackId(1),"Alpha");val remote=Track(TrackId(2),"Remote")
        val snapshot=DeviceListeningSnapshot(1,listOf(phone,unavailable),emptyList(),listOf(ListeningHistory(HistoryKey.Device(phone.id),100,null),ListeningHistory(HistoryKey.Server(ServerAccount("endpoint","owner"),ServerAudioId(1)),100,null)))
        val all=unifiedLibraryRows("endpoint","owner",listOf(server,remote),listOf(server),snapshot,LibraryQuery(),false,true)
        assertEquals(listOf("Alpha","Beta","Remote","Unavailable"),all.map {it.title})
        assertTrue(all[0].ref is PlaybackRef.Server);assertTrue(all[1].ref is PlaybackRef.Device)
        val local=unifiedLibraryRows("endpoint","owner",listOf(server,remote),listOf(server),snapshot,LibraryQuery(),true,true)
        assertEquals(listOf("Alpha","Beta"),local.map {it.title})
        assertEquals(listOf("Beta"),unifiedLibraryRows("endpoint",null,emptyList(),emptyList(),snapshot,LibraryQuery(text="beta"),true,true).map {it.title})
        assertEquals(2,unifiedLibraryRows("endpoint",null,emptyList(),emptyList(),snapshot,LibraryQuery(),false,true).size)
    }
    private fun phone(id:Int,title:String,vararg states:Pair<ScanGrantId,AccessState>)=DeviceAudio(DeviceFileId(UUID(0,id.toLong())),ProviderObjectId("fixture","$id"),ContentRevision("a".repeat(64),40),1,
        OriginalMetadata("$id.mp3",title),null,states.map {(grant,state)->LocatorAccess(grant,ProviderLocator("fixture","$id"),state)})
    @Test fun undecodablePhoneFileStaysVisibleInLocalFilesAsUnplayable() {
        val indexed=ScanGrant(ScanGrantId(UUID(2,1)),GrantKind.INDEXED,"Android audio index",ProviderLocator("android","indexed:external-audio"),false,AccessState.REVOKED)
        val folder=ScanGrant(ScanGrantId(UUID(2,2)),GrantKind.FOLDER,"Music",ProviderLocator("fixture","tree"),true,AccessState.REVOKED)
        val undecodable=phone(1,"Encrypted",indexed.id to AccessState.UNREADABLE)
        val unsupported=phone(2,"Protected",indexed.id to AccessState.UNSUPPORTED)
        val revoked=phone(3,"Revoked",indexed.id to AccessState.REVOKED)
        val lostFolder=phone(4,"Folder",folder.id to AccessState.REVOKED)
        val snapshot=DeviceListeningSnapshot(1,listOf(undecodable,unsupported,revoked,lostFolder),listOf(indexed,folder),emptyList())
        // A file that is present but cannot be decoded must not silently vanish from Local files after a failed tap.
        assertEquals(listOf("Encrypted","Protected"),unifiedLibraryRows("e",null,emptyList(),emptyList(),snapshot,LibraryQuery(),true,false).map {it.title}.sorted())
        assertEquals("Can’t play this file",phoneRowUnavailableLabel(undecodable,snapshot.grants))
        assertEquals("Can’t play this file",phoneRowUnavailableLabel(unsupported,snapshot.grants))
        // Indexed access off is not fixed by choosing the file again.
        assertEquals("Unavailable · Audio access is off",phoneRowUnavailableLabel(revoked,snapshot.grants))
        assertEquals("Unavailable · Choose file again",phoneRowUnavailableLabel(lostFolder,snapshot.grants))
    }
    @Test fun downloadsNeverDuplicateAcknowledgedServerIdentityAndPhoneCannotBecomeLiked() {
        val track=Track(TrackId(1),"Same",liked=true);val phone=file(1,"Same")
        val snapshot=DeviceListeningSnapshot(1,listOf(phone),emptyList(),emptyList())
        assertEquals(2,unifiedLibraryRows("e","a",listOf(track),listOf(track),snapshot,LibraryQuery(),true,false).size)
        assertEquals(1,unifiedLibraryRows("e","a",listOf(track),listOf(track),snapshot,LibraryQuery(liked=true),false,false).size)
        assertTrue(unifiedLibraryRows("e",null,emptyList(),listOf(track),snapshot,LibraryQuery(),true,false).single().ref is PlaybackRef.Device)
    }
}
