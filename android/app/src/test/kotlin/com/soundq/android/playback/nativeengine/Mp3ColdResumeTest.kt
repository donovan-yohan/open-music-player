package com.soundq.android.playback.nativeengine

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer

/** Virtual frame grammar only: no codec, provider or physical timing claim. */
class Mp3ColdResumeTest {
    private class Original(val rate:Int=48000,val variable:Boolean=false,val padded:Boolean=false) {
        private fun frame(index:Int,pad:Int=0)=ByteArray(144000*intArrayOf(0,32,40,48,56,64,80,96,112,128,160,192,224,256,320)[index]/rate+pad).apply {
            this[0]=0xff.toByte();this[1]=0xfb.toByte()
            this[2]=((index shl 4) or (intArrayOf(44100,48000,32000).indexOf(rate) shl 2) or (pad shl 1)).toByte()
        }
        val a=frame(14);val b=if(variable)frame(9,1)else frame(14,if(padded)1 else 0)
        private val cycle=a+b
        private val frames=(24L*3600*rate/1152+2).toInt()
        private val metadata=frame(14).apply {"Xing".toByteArray().copyInto(this,36)}
        val length=metadata.size+(frames/2L)*cycle.size+(if(frames%2==1)a.size else 0)
        var bytes=0L;var calls=0;var maximumRequest=0
        var headers=0L
        fun begin(){bytes=0;calls=0;maximumRequest=0}
        fun read(p:Long,d:ByteArray,o:Int,n:Int):Int {
            calls++;bytes+=n;maximumRequest=maxOf(maximumRequest,n)
            check(calls<=8192 && bytes<=32L*1024*1024) {"Original decoder read budget exceeded; unindexed seek refused"}
            return storage(p,d,o,n)
        }
        fun storage(p:Long,d:ByteArray,o:Int,n:Int):Int {
            var position=p;var out=o;var left=n
            while(left>0) {
                val input=if(position<metadata.size)metadata else cycle
                val at=if(position<metadata.size)position.toInt()else ((position-metadata.size)%cycle.size).toInt()
                val take=minOf(left,input.size-at);input.copyInto(d,out,at,at+take)
                position+=take;out+=take;left-=take
            }
            return n
        }
        fun parser()=Mp3OriginalFrames(length,::read,rate,2,mp3MetadataFixture({p,d,o,n ->headers++;storage(p,d,o,n)}))
    }
    @Test fun fresh48kXingReaderResumesObservedBookmarkWithoutPayloadPrefixReplay() {
        val source=Original();val p=source.parser()
        source.begin();p.seek(599L*48000) // reader.open eligibility witness
        source.begin();p.seek(0)
        source.begin()
        val first=(2018594L*48000/1000/48000)*48000-48000
        p.seek(first)
        assertEquals(first/1152*1152,p.sampleFrame)
        assertEquals(source.a.size,p.read(ByteBuffer.allocate(2048)))
        assertTrue("payload bytes=${source.bytes}",source.bytes<=65536)
    }
    @Test fun coldTrueVbrAndRationalPaddingKeepExactClockThrough24HourRange() {
        for(source in listOf(Original(variable=true),Original(rate=44100,padded=true))) {
            val p=source.parser();source.begin()
            val first=source.rate*86400L-source.rate
            p.seek(first);assertEquals(first/1152*1152,p.sampleFrame)
            source.begin();p.seek(first-48000);assertEquals((first-48000)/1152*1152,p.sampleFrame)
            source.begin();p.seek(0);assertEquals(0L,p.sampleFrame)
        }
    }
}
