package com.soundq.android.playback.mix

import com.soundq.android.data.mix.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Assume.assumeNotNull
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

class NativeMixJniTest {
    @Test fun actualJniProbeRejectsWrongDeclaredFramesAndPreSkip() {
        val fixture=System.getProperty("soundq.mix.fixture");assumeNotNull(fixture)
        val path=File(fixture!!,"0.opus").absolutePath
        NativeMix.probe(path,24000,312)
        assertTrue(runCatching {NativeMix.probe(path,23999,312)}.isFailure)
        assertTrue(runCatching {NativeMix.probe(path,24000,0)}.isFailure)
    }
    @Test fun actualJniDecoderScheduleReturnsTrimmedSamplesAndSeekableFloatWav() {
        val fixture=System.getProperty("soundq.mix.fixture");assumeNotNull(fixture)
        val source=File(fixture!!,"0.opus");val decoded=ByteBuffer.wrap(File(fixture,"0.decoded").readBytes()).order(ByteOrder.LITTLE_ENDIAN)
        val clip=MixJson.clip(Json.parseToJsonElement("""{"clipId":"a","queueItemId":"occ-a","trackId":7,"sourceStartMs":50,"sourceEndMs":300,"timelineStartMs":0,"gainDb":0,"tempoPolicy":"volumeOnly"}""").jsonObject)
        val plan=SavedMix("00000000-0000-4000-8000-000000000001",1,"Generated",listOf(clip))
        NativeMixStream(plan,mapOf(7L to source.absolutePath)).use {stream ->
            assertEquals(96044L,stream.size)
            val h=ByteArray(44);assertEquals(44,stream.read(0,h,0,h.size));assertEquals("RIFF",String(h,0,4));assertEquals(3,ByteBuffer.wrap(h).order(ByteOrder.LITTLE_ENDIAN).getShort(20).toInt())
            val bytes=ByteArray(8192)
            for(frame in listOf(0,4000,9000,10)) {
                val n=stream.read(44+frame*8L,bytes,0,bytes.size);assertEquals(bytes.size,n)
                val out=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
                repeat(n/4) {sample ->assertEquals(decoded.getFloat(((frame+2400)*2+sample)*4),out.float,.00008f)}
            }
            val tiny=ByteArray(5);assertEquals(5,stream.read(45,tiny,0,5))
            val expected=ByteArray(8);assertEquals(8,stream.read(44,expected,0,8))
            tiny.forEachIndexed {i,b ->assertEquals(expected[i+1],b)}
        }
    }
    @Test fun savedStemReplayMapsCanonicalChannelsAndSourceTimesIntoNativeSchedule() {
        val fixture=System.getProperty("soundq.mix.fixture");assumeNotNull(fixture)
        val paths=listOf("0.opus","1.opus","0.opus","1.opus").map {File(fixture!!,it).absolutePath}
        val edits=Json.parseToJsonElement("""{"schemaVersion":1,"channelSet":"stems4-demucs-v1","stemModelVersion":"audio-separator-htdemucs-ft-4s-v1","sourceFileHash":"sha256:${"a".repeat(64)}","events":[{"channel":"vocals","atMs":150,"gain":0.2,"rampMs":10}]}""")
        val c=MixJson.clip(Json.parseToJsonElement("""{"clipId":"a","queueItemId":"occ-a","trackId":7,"sourceStartMs":50,"sourceEndMs":300,"timelineStartMs":0,"gainDb":-6,"tempoPolicy":"volumeOnly","stemEdits":$edits}""").jsonObject)
        val plan=SavedMix("00000000-0000-4000-8000-000000000001",1,"Generated",listOf(c))
        val decoders=(0..1).map {ByteBuffer.wrap(File(fixture!!,"$it.decoded").readBytes()).order(ByteOrder.LITTLE_ENDIAN)}
        NativeMixStream(plan,emptyMap(),mapOf("a" to PreparedMixStems(listOf("vocals","drums","bass","other"),paths))).use {stream ->
            val bytes=ByteArray(2048*8);assertEquals(bytes.size,stream.read(44+4700*8,bytes,0,bytes.size))
            val out=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            repeat(2048){f ->val source=7100+f;val g=if(source<7200)1.0 else (1.0-.8*(source-7200)/480).coerceAtLeast(.2)
                repeat(2){ch ->val a=decoders[0].getFloat((source*2+ch)*4);val b=decoders[1].getFloat((source*2+ch)*4)
                    assertEquals(((a*g+a+b*2)*Math.pow(10.0,-6.0/20)).toFloat(),out.float,.00008f)}}
        }
    }
    @Test fun nativeSourceTimeAutomationRampsTheDecodedPcmRatherThanOnlyChangingMetadata() {
        val fixture=System.getProperty("soundq.mix.fixture");assumeNotNull(fixture)
        val path=File(fixture!!,"0.opus").absolutePath
        val handle=NativeMix.open(arrayOf(path),longArrayOf(1,0,12000,2400,0,0,1,0,-1,-1,-1,-1),floatArrayOf(1f),longArrayOf(0,7200,0,480),floatArrayOf(.2f))
        try {
            val bytes=ByteArray(2048*8);NativeMix.render(handle,4700,2048,bytes)
            val actual=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val original=ByteBuffer.wrap(File(fixture,"0.decoded").readBytes()).order(ByteOrder.LITTLE_ENDIAN)
            repeat(2048){f ->val source=7100+f;val gain=if(source<7200)1f else (1f-.8f*(source-7200)/480).coerceAtLeast(.2f)
                repeat(2){c ->assertEquals(original.getFloat((source*2+c)*4)*gain,actual.float,.00008f)}}
        }finally {NativeMix.close(handle)}
    }
}
