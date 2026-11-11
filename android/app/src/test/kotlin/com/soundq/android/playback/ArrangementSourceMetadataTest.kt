package com.soundq.android.playback

import com.soundq.android.data.timeline.*
import org.junit.Assert.*
import org.junit.Test

class ArrangementSourceMetadataTest {
    private fun clip(occurrence:String,start:Long,trimIn:Long=0,trimOut:Long=8000)=
        TimelineClip(occurrence,7,"Draft fallback",20000,trimIn,trimOut,start,QueueSegment.Context)
    private val names=mapOf("a" to ("First song" to "First artist"),"b" to ("Second song" to "Second artist"))

    @Test fun realTrimmedSourceIntervalsSelectUpcomingAcrossGapAndLastAtCompletion() {
        val document=TimelineDocument(clips=listOf(clip("a",1000,1000,4000),clip("b",6000,3000,7000)))
        for(position in listOf(0L,1000L,3999L))assertEquals("First song",document.arrangementMetadata(position,names::get).title)
        for(position in listOf(4000L,5999L,6000L,10000L,20000L))assertEquals("Second song",document.arrangementMetadata(position,names::get).title)
    }

    @Test fun duplicateRecordingUsesOccurrenceMetadataAndBothOverlapNames() {
        val document=TimelineDocument(clips=listOf(clip("a",0),clip("b",5000)))
        val overlap=document.arrangementMetadata(5000,names::get)
        assertEquals(listOf("a","b"),overlap.occurrences)
        assertEquals("First song → Second song",overlap.title)
        assertEquals("First artist → Second artist",overlap.artist)
        assertEquals("Second song",document.arrangementMetadata(8000,names::get).title)
    }

    @Test fun qualifiedPlaybackBpmUsesProjectedOutputEndWithoutChangingPolicy() {
        val first=clip("a",0)
        val source=TempoSourceIdentity("a",7,"source",20000,"bpm-revision","analysis_bpm",120.0,0.0,1,false)
        val held=TempoPlaybackIntent(source,150.0)
        val document=projectTempoDocument(TimelineDocument(clips=listOf(first,clip("b",5000)),playbackTempos=listOf(held)))
        assertEquals(6400L,document.clips.first().globalEndMs)
        assertEquals("First song → Second song",document.arrangementMetadata(6399,names::get).title)
        assertEquals("Second song",document.arrangementMetadata(6400,names::get).title)
        assertEquals(listOf(held),document.playbackTempos)
    }

    @Test fun missingArtistDoesNotInventRevisionAndMissingSourceUsesClipTitle() {
        val document=TimelineDocument(clips=listOf(clip("a",0)))
        val result=document.arrangementMetadata(0) {null}
        assertEquals("Draft fallback",result.title)
        assertEquals("",result.artist)
    }
}
