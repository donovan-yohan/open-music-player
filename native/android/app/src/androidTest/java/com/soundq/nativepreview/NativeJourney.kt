package com.soundq.nativepreview

import android.app.Instrumentation
import android.content.*
import android.media.session.MediaController
import android.os.*
import android.view.MotionEvent
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Opt-in test APK only. Uses generated fixture credentials staged in this
 * development package's private files, never another app/account. */
class NativeJourney : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    override fun onStart() {
        val checks = JSONArray()
        val samples = JSONArray()
        val result = JSONObject().put("kind", "actual production Kotlin service/JNI/Rust/Go fixture/native MediaPlayer journey")
        var service: PlaybackService? = null
        val connected = CountDownLatch(1)
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {service = (binder as PlaybackService.LocalBinder).service; connected.countDown()}
            override fun onServiceDisconnected(name: ComponentName) {service = null}
        }
        val context = targetContext
        fun onMain(action: () -> Unit) {
            var failure:Throwable? = null
            runOnMainSync {try {action()} catch (error:Throwable) {failure = error}}
            failure?.let {throw it}
        }
        fun waitFor(name: String, predicate: (PlaybackService) -> Boolean) {
            val deadline = SystemClock.elapsedRealtime()+15000
            while (true) {
                var passed = false
                onMain {service?.let {passed = predicate(it)}}
                if (passed) {checks.put(name);return}
                var diagnostics = ""
                onMain {service?.let {diagnostics = " native=${it.nativePositionMs()} playing=${it.nativePlaying()} state=${it.snapshot.optString("transport")} session=${it.snapshot.optLong("session")} error=${it.snapshot.optString("error")} seekRequested=${it.lastSeekRequested} seekCompleted=${it.lastSeekCompleted}"}}
                check(SystemClock.elapsedRealtime()<deadline) {name+diagnostics}
                Thread.sleep(50)
            }
        }
        fun sample(name: String, start: Long) {samples.put(JSONObject().put("name",name).put("durationMs",(SystemClock.elapsedRealtimeNanos()-start)/1e6))}
        var code = 0
        try {
            check(BuildConfig.API_BASE == "http://127.0.0.1:54761/api/v1") {"fixture endpoint required"}
            val privateFile = File(context.filesDir,"native-fixture-credentials.json")
            val credentials = JSONObject(privateFile.readText())
            val binding = CoreBridge()
            val unicodeCore = binding.open(BuildConfig.API_BASE,File(context.cacheDir,"unicode-音楽").absolutePath)
            check(unicodeCore!=0L) {"unicode JNI path"}
            val unicodeReply = JSONObject(binding.execute(unicodeCore,1,"{\"command\":\"library\",\"offset\":0,\"query\":\"🎵 音楽\",\"sort\":\"title\",\"order\":\"asc\"}"))
            check(unicodeReply.optString("code")=="unauthenticated") {"true UTF-8 JNI command"}
            binding.close(unicodeCore);checks.put("true UTF-8 JNI supplementary and CJK input")
            check(context.bindService(Intent(context,PlaybackService::class.java),connection,Context.BIND_AUTO_CREATE))
            check(connected.await(10,TimeUnit.SECONDS)) {"service binding"}
            onMain {service!!.login(credentials.getString("email"),credentials.getString("password"))}
            privateFile.delete()
            waitFor("real fixture login and first library page") {it.snapshot.optBoolean("authenticated") && it.snapshot.optJSONArray("library")?.length()==50}
            for (offset in 50 until 500 step 50) {
                onMain {service!!.library(offset)}
                waitFor("page $offset") {it.snapshot.optJSONArray("library")?.length()==offset+50}
            }
            var id = 0L
            onMain {id = service!!.snapshot.getJSONArray("library").getJSONObject(0).getLong("id")}
            val cleared = CountDownLatch(1)
            onMain {service!!.command(JSONObject().put("command","clear_cache")) {cleared.countDown()}}
            check(cleared.await(10,TimeUnit.SECONDS)) {"owned cache clear"}
            var start = SystemClock.elapsedRealtimeNanos()
            onMain {service!!.select(id)}
            waitFor("cold native decoder actually advances") {it.snapshot.optString("transport")=="playing" && it.snapshot.optLong("position_ms")>200}
            onMain {check(!service!!.lastEffectCached) {"cold unexpectedly cached"}}
            sample("cold_selection_to_first_reported_200ms_cursor",start)
            val activity = startActivitySync(Intent(context,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
            waitForIdleSync()
            // Mount real RecyclerView UI over the already-populated service.
            waitFor("populated Activity row binding") {activity.fixtureList?.adapter?.itemCount == 500}
            checks.put("real Activity renders 500 lazy native rows")
            start = SystemClock.elapsedRealtimeNanos()
            for (iteration in 0 until 8) {
                val points = IntArray(2);var width=0;var height=0
                onMain {activity.fixtureList!!.getLocationOnScreen(points);width=activity.fixtureList!!.width;height=activity.fixtureList!!.height}
                val down = SystemClock.uptimeMillis();val x=points[0]+width*0.5f;val y=points[1]+height*0.8f
                sendPointerSync(MotionEvent.obtain(down,down,MotionEvent.ACTION_DOWN,x,y,0))
                for (step in 1..12) {Thread.sleep(12);sendPointerSync(MotionEvent.obtain(down,SystemClock.uptimeMillis(),MotionEvent.ACTION_MOVE,x,y-height*0.55f*step/12,0))}
                sendPointerSync(MotionEvent.obtain(down,SystemClock.uptimeMillis(),MotionEvent.ACTION_UP,x,y-height*0.55f,0));Thread.sleep(80)
            }
            sample("eight_real_pointer_swipes_audio_active_500_rows",start)
            checks.put("actual pointer scroll while audio advances")
            val descriptor = uiAutomation.executeShellCommand("dumpsys gfxinfo com.soundq.nativepreview framestats")
            android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input -> File(context.filesDir,"native-framestats.txt").outputStream().use {input.copyTo(it)} }
            onMain {activity.moveTaskToBack(true)}
            waitFor("background after real Activity hides") {it.snapshot.optString("transport")=="playing"}
            onMain {service!!.command(JSONObject().put("command","pause"))}
            waitFor("pause actual native decoder") {!it.nativePlaying()}
            var paused = 0L
            onMain {paused = service!!.nativePositionMs()}
            Thread.sleep(700)
            onMain {check(kotlin.math.abs(service!!.nativePositionMs()-paused)<100) {"paused cursor drift"}}
            checks.put("paused native cursor stable")
            start = SystemClock.elapsedRealtimeNanos()
            onMain {service!!.command(JSONObject().put("command","seek").put("position_ms",6000))}
            waitFor("seek native cursor") {kotlin.math.abs(it.snapshot.optLong("position_ms")-6000)<150}
            sample("seek_to_actual_reported_cursor",start)
            onMain {service!!.command(JSONObject().put("command","resume"))}
            waitFor("resume actual cursor") {it.snapshot.optString("transport")=="playing" && it.snapshot.optLong("position_ms")>6200}
            // Re-select same occurrence via one canonical owner, warm bytes.
            var precedingSession=0L
            onMain {precedingSession=service!!.snapshot.optLong("session")}
            start = SystemClock.elapsedRealtimeNanos()
            onMain {service!!.select(id)}
            waitFor("warm cache native decoder advances") {it.snapshot.optLong("session")>precedingSession && it.nativePlaying() && it.nativePositionMs() in 201..5000}
            onMain {check(service!!.lastEffectCached) {"warm not cached"}}
            sample("warm_selection_to_first_reported_200ms_cursor",start)
            onMain {precedingSession=service!!.snapshot.optLong("session");service!!.command(JSONObject().put("command","retry"))}
            waitFor("retry advances") {it.snapshot.optLong("session")>precedingSession && it.nativePlaying() && it.nativePositionMs()>200}
            val controller = MediaController(context,service!!.sessionToken)
            controller.transportControls.pause()
            waitFor("OS media session pause dispatch") {it.snapshot.optString("transport")=="paused" && !it.nativePlaying()}
            controller.transportControls.seekTo(12000)
            waitFor("OS media session seek dispatch") {kotlin.math.abs(it.nativePositionMs()-12000)<200}
            controller.transportControls.play()
            waitFor("OS media session play dispatch") {it.snapshot.optString("transport")=="playing" && it.snapshot.optLong("position_ms")>12200}
            controller.transportControls.seekTo(29500)
            waitFor("native EOF is retained as terminal") {it.snapshot.optString("transport")=="ended"}
            Thread.sleep(650)
            onMain {check(service!!.snapshot.optString("transport")=="ended") {"EOF overwritten by paused tick"}}
            controller.transportControls.seekTo(12000);controller.transportControls.play()
            waitFor("explicit seek resume after EOF") {it.snapshot.optString("transport")=="playing" && it.nativePositionMs()>12200}
            Thread.sleep(1500)
            waitFor("bound UI absent background playback") {it.snapshot.optString("transport")=="playing" && it.snapshot.optLong("position_ms")>13500}
            controller.transportControls.pause()
            waitFor("final OS pause") {it.snapshot.optString("transport")=="paused"}
            onMain {precedingSession=service!!.snapshot.optLong("session");service!!.command(JSONObject().put("command","retry"));service!!.command(JSONObject().put("command","pause"))}
            waitFor("pause while preparing retains healthy decoder") {it.snapshot.optLong("session")>precedingSession && it.snapshot.optString("transport")=="paused" && !it.nativePlaying()}
            Thread.sleep(650)
            onMain {check(!service!!.nativePlaying() && service!!.snapshot.optString("transport")!="failed") {"late preparation revived pause or poisoned decoder"}}
            controller.transportControls.play()
            waitFor("explicit play after preparation pause") {it.nativePlaying() && it.nativePositionMs()>200}
            controller.transportControls.pause()
            waitFor("final native pause") {!it.nativePlaying()}
            result.put("status","passed")
        } catch (error: Throwable) {code = 1; result.put("status","failed").put("failure",error.javaClass.simpleName+": "+error.message)}
        finally {
            if (service != null) {onMain {service!!.logout()}; Thread.sleep(500)}
            try {context.unbindService(connection)} catch (_: Exception) {}
            context.stopService(Intent(context,PlaybackService::class.java))
        }
        result.put("checks",checks).put("samples",samples).put("sourceRef",BuildConfig.SOURCE_REF)
            .put("limits","One scripted emulator run with real Activity/RecyclerView pointer swipes, MediaPlayer cursor and OS MediaSession commands. Not physical hardware audibility, audio underrun trace or independent review; frame stats collected separately.")
        File(context.filesDir,"native-journey-report.json").writeText(result.toString(2))
        finish(if (code==0) android.app.Activity.RESULT_OK else android.app.Activity.RESULT_CANCELED,Bundle().apply {putString("status",result.optString("status"));putInt("checks",checks.length())})
    }
}
