package com.soundq.android.playback

import org.junit.Assert.*
import org.junit.Test

class ContinuationOriginTest {
    @Test fun continuationOriginSurvivesAcceptedArrangementSerializationAndCanonicalObserver() {
        val rows=listOf(QueueOccurrence("manual",1,"Manual","",true,2000),QueueOccurrence("continued",2,"Continued","",false,2000,QueueOrigin.Continuation))
        val sources=PlaybackProjection(PlaybackProjection.Connection.Connected,queue=rows).timelineSources()!!
        assertEquals(listOf(com.soundq.android.data.timeline.QueueSegment.Manual,com.soundq.android.data.timeline.QueueSegment.Continuation),sources.map {it.segment})
        val document=com.soundq.android.data.timeline.TimelineDocument(0,com.soundq.android.data.timeline.sequentialTimeline(sources))
        val accepted=AcceptedArrangement(ArrangementIdentity("service",1,"queue",0,"install"),document,rows)
        val encoded=kotlinx.serialization.json.Json.encodeToString(AcceptedArrangement.serializer(),accepted)
        val restored=kotlinx.serialization.json.Json.decodeFromString(AcceptedArrangement.serializer(),encoded)
        assertEquals(accepted,restored)
        val projection=PlaybackProjection(PlaybackProjection.Connection.Connected,source=PlaybackSource.Arrangement,arrangement=restored)
        assertEquals(sources,projection.timelineSources())
    }
    @Test fun legacyBooleanRowsDefaultToContextOrManualAndUnknownOriginsAreRejected() {
        fun raw(manual:Boolean,origin:String="")="""{"version":1,"endpoint":"e","account":"a","selected":0,"position":0,"items":[{"occurrence":"o","track":1,"title":"Track","artist":"A","manual":$manual$origin}]}"""
        assertEquals(QueueOrigin.Context,QueueSnapshot.decode(raw(false),"e","a")!!.items.single().origin)
        assertEquals(QueueOrigin.Manual,QueueSnapshot.decode(raw(true),"e","a")!!.items.single().origin)
        assertNull(QueueSnapshot.decode(raw(false,",\"origin\":\"Radio\""),"e","a"))
        assertNull(QueueSnapshot.decode(raw(true,",\"origin\":\"Continuation\""),"e","a"))
    }
    @Test fun manualEnqueueStillPrecedesContinuationTailAndDoesNotDeduplicateOccurrences() {
        val rows=listOf(SavedOccurrence("context",1,"A","",false),SavedOccurrence("manual",2,"B","",true),SavedOccurrence("auto",2,"B","",false,origin=QueueOrigin.Continuation))
        assertEquals(2,QueuePolicy.manualInsert(rows.map {it.manual},0))
        val saved=QueueSnapshot("e","a",rows,0,123)
        assertEquals(saved,QueueSnapshot.decode(saved.encode(),"e","a"))
    }
    @Test fun persistedContinuationIsNotSilentlyRestoredAsContext() {
        val raw="""{"version":1,"endpoint":"e","account":"a","selected":0,"position":0,"items":[{"occurrence":"o","track":1,"title":"Track","artist":"A","manual":false,"origin":"Continuation"}]}"""
        val saved=QueueSnapshot.decode(raw,"e","a")!!
        assertTrue("Continuation origin was discarded",saved.encode().contains("\"origin\":\"Continuation\""))
    }
}
