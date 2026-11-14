package com.soundq.android.playback.nativeengine
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
object CrossfadeDriver {@JvmStatic external fun render(count:Int):FloatArray}
private fun field(s:String,key:String):Double = s.substringAfter("\"$key\":").takeWhile {it!=',' && it!='}'}.toDouble()
private fun deck(s:String)=s.substringAfter("\"decks\":[").substringBefore('}')
private class GeneratedPeer:NativePcmReader {
    private var worker:Thread?=null
    @Volatile var calls=0;@Volatile var requested=0L;@Volatile var lowest=Long.MAX_VALUE;@Volatile var closes=0
    @Volatile var gate:CountDownLatch?=null
    var entered=CountDownLatch(1)
    @Volatile var failHeld=false
    @Volatile var failClose=false
    private var end=0L
    private val length=48000L*12600
    override fun open():Int {check(worker==null);worker=Thread.currentThread();check(worker!!.name!="main");return 48000}
    override fun read(first:Long,count:Int,destination:ByteBuffer):Int {
        check(Thread.currentThread()===worker);check(destination.isDirect);check(count<=48000)
        val held=gate
        if(held!=null) {gate=null;entered.countDown();check(held.await(5,TimeUnit.SECONDS));if(failHeld){failHeld=false;error("Obsolete target fill failed")}}
        calls++;requested+=count;lowest=min(lowest,first)
        val n=min(count.toLong(),(length-first).coerceAtLeast(0)).toInt()
        val out=destination.order(ByteOrder.nativeOrder())
        repeat(n){val sample=(.125*sin(2*PI*440*(first+it)/48000)).toFloat();out.putFloat(sample);out.putFloat(sample)}
        if(first+n>=length)end=length
        return n
    }
    override fun endFrames()=end
    override fun revoke(){}
    override fun closeReader():Boolean {check(Thread.currentThread()===worker);closes++;return !failClose}
}
fun main(args:Array<String>) {
    val closeFailure=args.firstOrNull()=="--close-failure"
    val peer=GeneratedPeer();val bridge=NativeCallbackBridge
    val handle=bridge.open();check(handle>0)
    try {
        check(bridge.loadReader(handle,0,peer,7,1,10800000,1.0))
        fun waitReady(target:Long) {
            val deadline=System.nanoTime()+15_000_000_000L
            while(true) {
                CrossfadeDriver.render(1)
                val d=deck(bridge.state(handle));check(field(d,"error")==0.0)
                if("\"ready\":true" in d && abs(field(d,"positionMs")-target)<10)break
                check(System.nanoTime()<deadline);Thread.sleep(1)
            }
        }
        waitReady(10800000)
        check(peer.lowest>=48000L*10799 && peer.requested<=48000*4)
        check(field(deck(bridge.state(handle)),"sourceFrames")==0.0)
        check(bridge.control(handle,1,0,0.0,0))
        val pcm=CrossfadeDriver.render(256)
        for(i in 0 until 256) {
            val expected=(.125*sin(2*PI*440*i/48000)).toFloat()
            check(abs(pcm[i*2]-expected)<1e-6) {"Sample $i ${pcm[i*2]} != $expected"}
        }
        check(field(deck(bridge.state(handle)),"naturalEndCount")==0.0)
        check(bridge.control(handle,2,0,0.0,0))
        val gate=CountDownLatch(1);peer.gate=gate;peer.failHeld=true
        check(bridge.control(handle,3,0,3600000.0,0))
        CrossfadeDriver.render(1) // controlled OS output must consume the real Seek
        check(peer.entered.await(5,TimeUnit.SECONDS))
        check(bridge.control(handle,3,0,7200000.0,0)) // independent latest seek while old fill owns bytes
        CrossfadeDriver.render(1)
        gate.countDown();waitReady(7200000)
        check(bridge.control(handle,3,0,3600000.0,0));waitReady(3600000)
        check(peer.requested<48000*16)
        println("PASS held obsolete seek failure cannot close the current decoder or publish old target")
        if(closeFailure) {
            peer.failClose=true
            check(bridge.control(handle,8,0,0.0,0))
            val end=System.nanoTime()+5_000_000_000L
            while(field(bridge.state(handle),"error")==0.0){CrossfadeDriver.render(1);Thread.sleep(1);check(System.nanoTime()<end)}
            check(field(deck(bridge.state(handle)),"identity")==7.0)
            check(field(bridge.state(handle),"openDecoders")>=1.0)
        }
        println("PASS production JNI/Host/WorkerDeck/Engine: direct 3h resume, every-sample oracle, bounded backward 1h seek; requested=${peer.requested} calls=${peer.calls}")
    } finally {
        if(closeFailure) {check(!bridge.close(handle));check(bridge.open()==0L)}
        else {check(bridge.close(handle));check(peer.closes==1)}
    }
    println(if(closeFailure)"PASS failed peer close retains native identity, decoder budget and singleton; original-delete release refused" else "PASS JVM peer released on decoder worker before native close ACK")
}
