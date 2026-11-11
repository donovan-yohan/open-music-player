package com.soundq.android.playback.nativeengine

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.serialization.json.*

private class JSONObject private constructor(private val value:JsonObject) {
    constructor(raw:String):this(Json.parseToJsonElement(raw).jsonObject)
    fun getLong(key:String)=value.getValue(key).jsonPrimitive.long
    fun getInt(key:String)=value.getValue(key).jsonPrimitive.int
    fun getDouble(key:String)=value.getValue(key).jsonPrimitive.double
    fun getBoolean(key:String)=value.getValue(key).jsonPrimitive.boolean
    fun getJSONArray(key:String)=value.getValue(key).jsonArray.map{JSONObject(it.jsonObject)}
    override fun toString()=value.toString()
}
private fun List<JSONObject>.getJSONObject(index:Int)=get(index)

internal object CrossfadeDriver { @JvmStatic external fun render(frames:Int):FloatArray }
/** Actual production bridge/decoder/worker/core; only device output is controlled. */
fun main(args:Array<String>) {
    val h=NativeCallbackBridge.open();check(h>0)
    fun state()=JSONObject(NativeCallbackBridge.state(h))
    fun deck(slot:Int)=state().getJSONArray("decks").getJSONObject(slot)
    fun tick(n:Int=1)=CrossfadeDriver.render(n)
    fun await(test:()->Boolean) {
        val end=System.nanoTime()+10_000_000_000L
        while(!test()){check(System.nanoTime()<end){state().toString()};tick();Thread.sleep(1)}
    }
    fun control(op:Int,d:Int=0,v:Double=0.0) {check(NativeCallbackBridge.control(h,op,d,v,0))}
    fun load(slot:Int,generation:Long,path:String) {check(NativeCallbackBridge.load(h,slot,path,generation,generation,0))}
    fun capture(frames:Int):FloatArray {
        val result=FloatArray(frames*2);var at=0
        while(at<frames){state();val n=minOf(173,frames-at);val block=tick(n);block.copyInto(result,at*2);at+=n;Thread.sleep(1)}
        return result
    }
    fun save(name:String,samples:FloatArray) {
        val data=ByteBuffer.allocate(samples.size*4).order(ByteOrder.LITTLE_ENDIAN)
        samples.forEach{data.putFloat(it)};File(args[2],name).writeBytes(data.array())
    }
    try {
        load(0,11,args[0]);load(1,12,args[1])
        await{deck(0).getBoolean("ready")&&deck(1).getBoolean("ready")}
        check(state().getInt("openDecoders")==2)
        check(!NativeCallbackBridge.crossfade(h,0,10,1,12,1000))
        check(!NativeCallbackBridge.crossfade(h,0,11,1,12,12001))
        check(NativeCallbackBridge.crossfade(h,0,11,1,12,1000))
        tick();repeat(5){check(tick(256).all{it==0f})} // arm/load never Play
        check(deck(0).getDouble("sourceFrame")==0.0&&deck(1).getDouble("sourceFrame")==0.0)
        control(1)
        save("before-pause.f32",capture(264000)) // 5.5s of a six-second source, midpoint
        val a=deck(0);val b=deck(1)
        check(kotlin.math.abs(a.getDouble("boundaryGain")-b.getDouble("boundaryGain"))<1e-12)
        check(a.getLong("eofCount")==0L&&b.getLong("positionMs")==500L)
        control(2,1);tick()
        val frozen0=deck(0).getDouble("sourceFrame");val frozen1=deck(1).getDouble("sourceFrame")
        repeat(4){check(tick(173).all{it==0f})}
        check(deck(0).getDouble("sourceFrame")==frozen0&&deck(1).getDouble("sourceFrame")==frozen1)
        control(1,1)
        save("after-pause.f32",capture(72000)) // outgoing EOF, incoming already at 2s
        check(deck(0).getLong("eofCount")==1L&&deck(1).getLong("eofCount")==0L)
        // EOF is not a source retirement fence. Both decoder owners still exist.
        check(state().getInt("openDecoders")==2)
        control(2,1);tick()
        check(NativeCallbackBridge.crossfade(h,1,12,0,11,0));tick()
        control(8,0)
        check(deck(0).getLong("identity")==11L) // no callback ACK yet
        await{deck(0).getLong("identity")==0L&&deck(0).getInt("openDecoders")==0}
        check(deck(1).getLong("identity")==12L&&state().getInt("openDecoders")==1)
        // Retired slot reuse and duplicate-file independent cursor; never reload on-air b.
        load(0,13,args[1]);await{deck(0).getBoolean("ready")}
        check(deck(0).getLong("positionMs")==0L&&kotlin.math.abs(deck(1).getLong("positionMs")-2000L)<=1L)
        check(NativeCallbackBridge.crossfade(h,1,12,0,13,1000));tick()
        check(NativeCallbackBridge.crossfade(h,1,12,0,13,0));tick()
        control(3,1,4500.0);tick()
        await{deck(1).getBoolean("ready")&&kotlin.math.abs(deck(1).getLong("positionMs")-4500L)<=1L}
        control(1,1)
        save("seek.f32",capture(256))
        control(8,0);await{deck(0).getLong("identity")==0L}
        control(8,1);await{deck(1).getLong("identity")==0L}
        check(state().getInt("openDecoders")==0)
        File(args[2],"retired.json").writeText(state().toString())
        println("PASS production Kotlin/JNI/Host/WorkerDeck/codec: midpoint, pause, EOF != release, exact unassign/decoder drain, slot reuse, duplicate bytes, source-local seek")
    } finally {check(NativeCallbackBridge.close(h))}
}
