package com.soundq.android.playback.nativeengine

import java.io.File
import kotlin.math.abs

// Only resource/error boundaries for the extracted, unchanged MP3 test method.
// No successful codec/JNI result is synthesized by this probe.
class ContextFacade(val cacheDir:File)
class AssetsFacade(val frame:File) {fun open(name:String)=frame.inputStream()}
class OriginalAudioReadLease {
    var closed=false
    val totalReadBytes=0L;val totalReadCalls=0L
    fun close(){closed=true}
}
class AndroidPlatformWindowReader(val source:OriginalAudioReadLease) {
    fun closeReader():Boolean {
        closes++
        if(NativeCallbackBridge.mode=="cleanup-fails")return false
        source.close();return true
    }
    companion object {var closes=0}
}
object NativeCallbackBridge {
    var mode="";var opens=0;var closes=0
    val primary=IllegalStateException("fixture original JNI failure")
    fun open():Long {opens++;if(mode=="open-throws")throw primary;return if(mode=="open-zero")0 else 9}
    fun close(handle:Long):Boolean {check(handle==9L);closes++;return false}
    fun loadReader(handle:Long,deck:Int,reader:AndroidPlatformWindowReader,id:Long,generation:Long,position:Long,speed:Double):Boolean=throw primary
    fun state(handle:Long):String=error("No successful JNI path in resource probe")
    fun control(handle:Long,operation:Int,deck:Int,value:Double,event:Long):Boolean=error("No output in resource probe")
}
class JSONObject(value:String="") {
    fun getJSONArray(key:String):JSONArray=error("Not a JSON/codec acceptance probe")
    fun getBoolean(key:String):Boolean=error("unreachable")
    fun getInt(key:String):Int=error("unreachable")
    fun getLong(key:String):Long=error("unreachable")
    fun optLong(key:String):Long=error("unreachable")
}
class JSONArray {fun getJSONObject(index:Int):JSONObject=error("unreachable")}
fun assertTrue(value:Boolean) {if(!value)throw AssertionError("fixture assertion false")}
fun assertTrue(message:String,value:Boolean) {if(!value)throw AssertionError(message)}
fun assertEquals(a:Long,b:Long) {check(a==b)}
fun assertEquals(a:Int,b:Int) {check(a==b)}

fun main(args:Array<String>) {
    NativeCallbackBridge.mode=args[0]
    val root=File(args[1]).apply {check(mkdir())}
    val fixture=ExtractedMp3Fixture(root,File(args[2]))
    try {
        val failure=runCatching {fixture.mp3AboveOldCapPrimesDeepTargetThroughSoleNativeCallbackEngine()}.exceptionOrNull()
        check(failure!=null)
        check(NativeCallbackBridge.opens==1)
        if(args[0]=="cleanup-fails") {
            check(failure===NativeCallbackBridge.primary) {"Cleanup replaced the primary: $failure"}
            check(NativeCallbackBridge.closes==1 && AndroidPlatformWindowReader.closes==1)
            check(failure.suppressed.size==3) {"Both failed closes and refused unlink must be attached: ${failure.suppressed.toList()}"}
            check(root.listFiles()!!.size==1 && fixture.source?.closed==false) {"Failed concrete custody must retain original"}
        } else {
            if(args[0]=="open-throws")check(failure===NativeCallbackBridge.primary)
            else check(failure is AssertionError)
            check(NativeCallbackBridge.closes==0) {"Never close an unacquired native handle"}
            check(AndroidPlatformWindowReader.closes==1 && fixture.source?.closed==true) {"Open failure leaked reader/lease"}
            check(root.listFiles()!!.isEmpty()) {"Open failure leaked generated original"}
        }
        println("PASS ${args[0]}: actual extracted MP3 method preserves primary, attempts owned cleanup, fences unlink")
    } finally {
        // Exact host-probe-owned generated files only, after the custody observations above.
        root.listFiles()!!.forEach {check(it.parentFile==root && it.name.startsWith("original-3-5h-"));check(it.delete())}
        check(root.delete())
    }
}
