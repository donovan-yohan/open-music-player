package com.soundq.android.playback.nativeengine

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer

/** Deterministic packet grammar, not a substitute for real encoded/codec oracles.
 * Virtual positioned storage keeps the 3.5-hour regression independent of heap/file size.
 */
class Mp3SeekIndexTest {
    private class Original(val variable:Boolean=false,val frames:Int=350001,val declared:Boolean=true,
        val infoName:String?=null,val countDelta:Int=0,val bytesDelta:Int=0,val padded:Boolean=false) {
        private fun frame(bitrate:Int,padding:Int=0)=ByteArray(144000*intArrayOf(0,32,40,48,56)[bitrate]/32000+padding).apply {
            this[0]=0xff.toByte();this[1]=0xfb.toByte();this[2]=((bitrate shl 4) or 8 or (padding shl 1)).toByte();this[3]=0xc0.toByte()
        }
        val a=frame(3,if(padded)1 else 0);val b=if(variable)frame(4,1)else a
        private val cycle=a+b
        private val metadata=frame(3).apply {
            (infoName ?: if(variable)"Xing" else "Info").toByteArray().copyInto(this,21)
            if(declared) {put32(this,25,3);put32(this,29,frames.toLong()+countDelta);put32(this,33,216+audioBytes()+bytesDelta)}
        }
        val length=216+audioBytes()
        var bytes=0L;var calls=0;var maxBytes=0L;var maxCalls=0
        var valid=true
        var faultAt=-1L
        var faultValue=0.toByte()
        var failure:Throwable?=null
        private fun audioBytes()=(frames/2L)*(a.size+b.size)+(if(frames%2==1)a.size else 0)
        fun begin() {maxBytes=maxOf(maxBytes,bytes);maxCalls=maxOf(maxCalls,calls);bytes=0;calls=0}
        fun parser()=Mp3OriginalFrames(length,{p,d,o,n ->
            check(valid) {"Original changed or revoked"};failure?.let {throw it}
            calls++;bytes+=n
            check(calls<=8192 && bytes<=32L*1024*1024) {"Original decoder read budget exceeded; unindexed seek refused"}
            require(p>=0 && p+n<=length)
            var position=p;var out=o;var left=n
            while(left>0) {
                val input=if(position<216)metadata else cycle
                val at=if(position<216)position.toInt() else ((position-216)%cycle.size).toInt()
                val take=minOf(left,input.size-at);input.copyInto(d,out,at,at+take)
                position+=take;out+=take;left-=take
            }
            if(faultAt in p until p+n)d[o+(faultAt-p).toInt()]=faultValue
            n
        },32000,1)
    }
    @Test fun coldThreeHourInfoTargetIsExactAndBoundedWithoutPrefixReplay() {
        val source=Original();val p=source.parser();source.begin()
        val first=10800L*32000-32000
        p.seek(first)
        assertEquals(first/1152*1152,p.sampleFrame)
        assertEquals(216,p.read(ByteBuffer.allocate(2048)))
        assertTrue("cold target bytes=${source.bytes}",source.bytes<=2*65536)
        assertTrue(source.calls<=2)
    }
    @Test fun workerOverlapRefillsKeepExactClockAcrossLongVariableBitrateOriginal() {
        val source=Original(variable=true);val p=source.parser();val buffer=ByteBuffer.allocate(2048)
        // WorkerDeck neighborhoods [c,c+1], [c+1,c+2]; each page is a
        // separate 48000-frame reader call and each seek has one second preroll.
        for(c in 0L..402000000L step 48000L) {
            for(first in listOf(c,c+48000)) {
                source.begin();p.seek(maxOf(0,first-32000))
                assertEquals(maxOf(0,first-32000)/1152*1152,p.sampleFrame)
                while(p.sampleFrame<first+48000) {buffer.clear();assertTrue(p.read(buffer)>0);p.advance()}
                assertTrue("overlap $first bytes=${source.bytes}",source.bytes<=1024*1024)
            }
        }
    }
    @Test fun fourPageForwardRefillsUseBoundedExactCheckpointsForTheirThreePageOverlap() {
        val source=Original(variable=true);val p=source.parser();val buffer=ByteBuffer.allocate(2048)
        for(c in 0L..402000000L step 48000L)for(page in 0..3) {
            val first=c+page*48000L
            source.begin();p.seek(maxOf(0,first-32000))
            assertEquals(maxOf(0,first-32000)/1152*1152,p.sampleFrame)
            while(p.sampleFrame<first+48000) {buffer.clear();assertTrue(p.read(buffer)>0);p.advance()}
            assertTrue("four-page overlap $first bytes=${source.bytes}",source.bytes<=1024*1024)
        }
    }
    @Test fun completedTraversalSupportsBackwardRepeatedAndOutOfOrderExactWindows() {
        val source=Original(variable=true);val p=source.parser()
        // Gather genuine exact checkpoints with bounded forward operations.
        for(first in 0L..345600000L step 960000L) {source.begin();p.seek(first)}
        for(first in listOf(345600000L,179520000L,0L,179520000L,345600000L,48000L)) {
            source.begin();p.seek(first);assertEquals(first/1152*1152,p.sampleFrame)
            assertTrue(source.bytes<=1024*1024)
        }
    }
    @Test fun coldUnindexedVariableBitrateStillRefusesRatherThanInventingAnExactClock() {
        val source=Original(variable=true);val p=source.parser();source.begin()
        val failure=runCatching {p.seek(10800L*32000)}.exceptionOrNull()
        assertTrue(failure is IllegalStateException)
        assertTrue(failure!!.message!!.contains("budget"))
    }
    @Test fun changedOrRevokedOriginalCannotUseRetainedSeekCheckpoint() {
        val source=Original(variable=true);val p=source.parser();source.begin();p.seek(320000)
        source.valid=false;source.begin()
        assertEquals("Original changed or revoked",runCatching {p.seek(320000)}.exceptionOrNull()?.message)
    }
    @Test fun exactInfoSeekStillPropagatesStorageFailure() {
        val source=Original();val p=source.parser();source.begin()
        val failure=IllegalStateException("positioned read failed");source.failure=failure
        assertSame(failure,runCatching {p.seek(10800L*32000)}.exceptionOrNull())
    }
    @Test fun missingInconsistentOrXingCountsNeverBecomeAnArithmeticIndex() {
        for(source in listOf(Original(declared=false),Original(countDelta=1),Original(bytesDelta=1),Original(infoName="Xing"),Original(padded=true))) {
            val p=source.parser();source.begin();p.seek(600L*32000)
            assertEquals(600L*32000/1152*1152,p.sampleFrame)
            assertTrue("unqualified index must actually count headers",source.bytes>2*65536)
        }
    }
    @Test fun exactInfoTargetValidatesRealHeaderAndFormatRatherThanReturningFalseEos() {
        for((offset,value) in listOf(0 to 0,3 to 0)) {
            val source=Original();val p=source.parser();source.begin()
            val first=10800L*32000
            source.faultAt=216+(first/1152)*216+offset;source.faultValue=value.toByte()
            assertTrue(runCatching {p.seek(first)}.exceptionOrNull() is IllegalArgumentException)
        }
    }
    @Test fun checkpointStorageHasAnAbsoluteRecordingIndependentCap() {
        val source=Original(variable=true,frames=5000000);val p=source.parser()
        for(bucket in 0L..4100L) {source.begin();p.seek(bucket*960000)}
        val retained=p.javaClass.declaredFields.filter {Map::class.java.isAssignableFrom(it.type)}.sumOf {
            it.isAccessible=true;(it.get(p) as Map<*,*>).size
        }
        assertTrue(retained<=4096)
        source.begin();p.seek(0);assertEquals(0L,p.sampleFrame)
    }
    @Test fun infoByteAndFrameCountsDoNotReplaceActualEncodedEos() {
        val source=Original();val p=source.parser();source.begin()
        val last=source.frames*1152L
        p.seek(last-1);assertEquals(last-1152,p.sampleFrame)
        p.advance();assertEquals(-1,p.read(ByteBuffer.allocate(2048)))
        source.begin();p.seek(last+1152);assertEquals(-1,p.read(ByteBuffer.allocate(2048)))
    }
    companion object {
        private fun put32(bytes:ByteArray,at:Int,value:Long) {repeat(4){bytes[at+it]=(value shr (24-it*8)).toByte()}}
    }
}
