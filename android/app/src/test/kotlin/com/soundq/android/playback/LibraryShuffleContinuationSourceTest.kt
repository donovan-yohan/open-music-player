package com.soundq.android.playback

import com.soundq.android.data.*
import org.junit.Assert.*
import org.junit.Test
import kotlin.random.Random

class LibraryShuffleContinuationSourceTest {
    private fun page(ids:List<Long>,total:Int=ids.size,offset:Int=0,duration:Long=2000)="""{"tracks":[${ids.joinToString(","){"""{"id":$it,"title":"Track $it","duration_ms":$duration}"""}}],"total":$total,"limit":100,"offset":$offset}"""
    private fun fixture(test:(HttpsFixture,LibraryShuffleContinuationSource,AccountScope)->Unit) {
        HttpsFixture().use {f->val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"));test(f,LibraryShuffleContinuationSource(SoundQApi(session,f.client),Random(4)),session.capture()!!)}
    }
    @Test fun freshShufflePrecedesOldestRecentRelaxationWithoutHardExclusions()=fixture {f,s,scope->
        f.reply(page((1L..8L).toList()+2));val selected=s.fetch(scope,setOf(1,8),listOf(2,3,4),20,System.nanoTime()+15_000_000_000L){true}.map {it.id.value}
        assertEquals(setOf(5L,6L,7L),selected.take(3).toSet());assertEquals(listOf(2L,3L,4L),selected.drop(3));assertEquals(6,selected.distinct().size)
    }
    @Test fun onlyCurrentAndFutureTailAreHardExcludedNotPlayedHistory()=fixture {f,s,scope->
        f.reply(page(listOf(1,2,3,4)));assertEquals(listOf(1L,2L),s.fetch(scope,setOf(3,4),listOf(1,2),20,System.nanoTime()+15_000_000_000L){true}.map {it.id.value})
    }
    @Test fun batchLimitIsTwentyAndDurationThresholdIsInclusive()=fixture {f,s,scope->
        f.reply(page((1L..30L).toList(),duration=1000));assertEquals(20,s.fetch(scope,emptySet(),emptyList(),20,System.nanoTime()+15_000_000_000L){true}.size)
        f.reply(page(listOf(1,2),duration=999));assertTrue(s.fetch(scope,emptySet(),emptyList(),20,System.nanoTime()+15_000_000_000L){true}.isEmpty())
    }
    @Test fun fixedInitialTotalStopsDespiteLaterMovingTotal()=fixture {f,s,scope->
        f.reply(page(listOf(1,2),total=3));f.reply(page(listOf(3,4),total=10000,offset=2))
        assertEquals(4,s.fetch(scope,emptySet(),emptyList(),20,System.nanoTime()+15_000_000_000L){true}.size);assertEquals(2,f.server.requestCount)
    }
    @Test fun invalidIdsAreFilteredWithoutLosingRawPageProgress()=fixture {f,s,scope->
        f.reply("""{"tracks":[{"id":0,"title":"Invalid","duration_ms":2000},{"id":-1,"title":"Invalid","duration_ms":2000},{"id":2,"title":"Valid","duration_ms":2000}],"total":4,"limit":100,"offset":0}""")
        f.reply(page(listOf(3),total=4,offset=3))
        assertEquals(setOf(2L,3L),s.fetch(scope,emptySet(),emptyList(),20,System.nanoTime()+15_000_000_000L){true}.map {it.id.value}.toSet())
    }
    @Test fun invalidDeadlineAndRevokedReadNeverDispatch()=fixture {f,s,scope->
        assertTrue(runCatching {s.fetch(scope,emptySet(),emptyList(),20,0){true}}.exceptionOrNull() is SafeFailure)
        assertTrue(runCatching {s.fetch(scope,emptySet(),emptyList(),20,Long.MAX_VALUE){false}}.exceptionOrNull() is SafeFailure);assertEquals(0,f.server.requestCount)
    }
}
