package com.soundq.android.product

import com.soundq.android.data.preferences.KeyNotationState
import com.soundq.android.playback.*
import org.junit.Assert.*
import org.junit.Test

/** Invokes real caller formatters, including private UI helpers, without replacing their bodies. */
class LongDurationCallersTest {
    private fun call(file:String,name:String,ms:Long?,nullable:Boolean=false):String {
        val type=if(nullable)java.lang.Long::class.java else java.lang.Long.TYPE
        return Class.forName("com.soundq.android.product.$file").getDeclaredMethod(name,type).let {
            it.isAccessible=true;it.invoke(null,ms) as String
        }
    }
    @Test fun everyDurationCallerUsesTwoDigitHourClocks() {
        val callers=listOf(Triple("QueuePanelKt","queueTime",false),
            Triple("playlists.PlaylistDetailScreenKt","mixTime",false),
            Triple("timeline.StackedTimelineKt","timelineTime",false),
            Triple("trackdetails.TrackDetailsSheetKt","detailsDuration",true),
            Triple("discovery.DiscoverScreenKt","duration",false),
            Triple("catalog.CatalogScreenKt","duration",true))
        for ((ms,expected) in listOf(3_599_999L to "59:59",3_600_000L to "01:00:00",12_372_000L to "03:26:12",360_000_000L to "100:00:00",Long.MAX_VALUE to "2562047788015:12:55")) {
            for ((file,name,nullable) in callers)assertEquals("$file.$name($ms)",expected,call(file,name,ms,nullable))
            assertEquals(expected,libraryRowMetadata(ms,null,KeyNotationState()).single().display)
            assertEquals(expected,memberDurationMetadata(ms).single().display)
        }
    }
    @Test fun callerSpecificUnknownPlaceholdersStayIntact() {
        assertEquals("Not available",call("trackdetails.TrackDetailsSheetKt","detailsDuration",null,true))
        assertEquals("Not available",call("trackdetails.TrackDetailsSheetKt","detailsDuration",-1,true))
        assertEquals("Duration unavailable",call("catalog.CatalogScreenKt","duration",null,true))
        assertEquals("Duration unavailable",call("catalog.CatalogScreenKt","duration",0,true))
        assertEquals("Duration unavailable",call("discovery.DiscoverScreenKt","duration",-1))
        assertTrue(libraryRowMetadata(-1,null,KeyNotationState()).isEmpty())
        assertEquals("—:—",memberDurationMetadata(-1).single().display)
    }
    @Test fun realCompactAdapterKeepsCanonicalPositionDurationAndInternalPreparation() {
        val row=QueueOccurrence("a",1,"Title","Artist",false,12_372_000)
        val p=PlaybackProjection(connection=PlaybackProjection.Connection.Connected,title="Title",artist="Artist",queue=listOf(row),selectedOccurrence="a",positionMs=3_600_000,durationMs=12_372_000,preparing=true)
        val t=projectCompactSongTiming(p,row)
        assertEquals("01:00:00 / 03:26:12",t.clockText)
        assertEquals(com.soundq.designsystem.CompactPlaybackState.Preparing,t.state)
        assertEquals(p.positionMs,t.elapsed);assertEquals(p.durationMs,t.total)
    }
}
