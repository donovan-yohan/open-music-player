package com.soundq.nativepreview

import android.app.*
import android.content.*
import android.media.*
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.*
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.util.Base64

class CoreBridge {
    companion object { init { System.loadLibrary("soundq_core"); System.loadLibrary("soundq_jni") } }
    external fun open(endpoint: String, root: String): Long
    external fun version(): Int
    external fun execute(handle: Long, epoch: Long, command: String): String
    external fun revoke(handle: Long): Long
    external fun close(handle: Long)
}

class PlaybackService : Service() {
    inner class LocalBinder : Binder() { val service: PlaybackService get() = this@PlaybackService }
    private val binder = LocalBinder()
    private val bridge = CoreBridge()
    private var core = 0L
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var playerReady = false
    private var pendingSeekMs: Long? = null
    private var nativeTerminalState: String? = null
    private lateinit var session: MediaSession
    private lateinit var audio: AudioManager
    private lateinit var focus: AudioFocusRequest
    private var focusHeld = false
    private var foreground = false
    private var notificationIdentity = ""
    private var wantsPlayback = false
    private var pendingReports = false
    private var busy = 0
    var epoch = 1L
        private set
    var snapshot = JSONObject()
        private set
    var listener: ((JSONObject, String?) -> Unit)? = null
    val sessionToken get() = session.sessionToken
    var lastEffectCached = false
        private set
    internal fun nativePositionMs(): Long = try {player?.currentPosition?.toLong() ?: 0} catch (_:IllegalStateException) {0}
    internal fun nativePlaying(): Boolean = try {player?.isPlaying == true} catch (_:IllegalStateException) {false}
    internal var lastSeekRequested = -1L
        private set
    internal var lastSeekCompleted = -1L
        private set
    private val endpoint get() = BuildConfig.API_BASE
    private val tick = object : Runnable {
        override fun run() { report(); main.postDelayed(this, 500) }
    }
    private val noisy = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) { command(JSONObject().put("command", "pause")) }
    }
    override fun onCreate() {
        super.onCreate()
        check(bridge.version()==1) {"Unsupported application core ABI"}
        core = bridge.open(endpoint, File(cacheDir, "audio-v1").absolutePath)
        check(core != 0L) {"Application core configuration refused"}
        audio = getSystemService(AudioManager::class.java)
        focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setOnAudioFocusChangeListener({ change ->
                if (change <= AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) command(JSONObject().put("command", "pause"))
                // No automatic replay after focus loss. User explicitly resumes.
            }, main).build()
        session = MediaSession(this, "SoundQNative")
        session.setCallback(object : MediaSession.Callback() {
            override fun onPlay() { command(JSONObject().put("command", "resume")) }
            override fun onPause() { command(JSONObject().put("command", "pause")) }
            override fun onSeekTo(pos: Long) { lastSeekRequested = pos;command(JSONObject().put("command", "seek").put("position_ms", pos)) }
            override fun onStop() { command(JSONObject().put("command", "pause")) }
        }, main)
        session.isActive = true
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("playback", "Playback", NotificationManager.IMPORTANCE_LOW))
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(noisy, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), RECEIVER_NOT_EXPORTED)
        else registerReceiver(noisy, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        main.post(tick)
        val saved = loadCredentials()
        if (saved != null) command(saved.put("command", "restore")) { library() }
        else command(JSONObject().put("command", "snapshot"))
    }
    override fun onBind(intent: Intent): IBinder = binder
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "pause" -> command(JSONObject().put("command", "pause"))
            "play" -> command(JSONObject().put("command", "resume"))
        }
        return START_NOT_STICKY
    }
    fun command(value: JSONObject, done: (() -> Unit)? = null) {
        if (busy >= 32) {listener?.invoke(snapshot,"command_backpressure");return}
        val kind = value.optString("command")
        if (kind in listOf("select","resume","retry")) wantsPlayback = true
        if (kind in listOf("pause","logout","login")) {wantsPlayback = false;try {player?.pause()} catch (_: IllegalStateException) {}}
        val admitted = epoch
        val raw = value.toString()
        busy++
        worker.execute {
            val result = try { JSONObject(bridge.execute(core, admitted, raw)) } catch (_: Exception) { JSONObject().put("ok", false).put("code", "binding_failure") }
            main.post {
                busy--
                if (admitted != epoch) {pendingReports = false;return@post}
                val next = result.optJSONObject("snapshot")
                if (next != null && next.optLong("epoch") == epoch) {
                    if (next.optBoolean("library_unchanged")) next.put("library",snapshot.optJSONArray("library") ?: org.json.JSONArray())
                    snapshot = next
                    listener?.invoke(snapshot, if (result.optBoolean("ok")) null else result.optString("code"))
                } else if (!result.optBoolean("ok")) listener?.invoke(snapshot, result.optString("code"))
                result.optJSONObject("audio")?.let { if (it.optLong("epoch") == epoch) applyAudio(it) }
                if (result.optBoolean("ok") && kind in listOf("restore","library") && snapshot.optBoolean("authenticated")) saveCredentials()
                updateSession()
                done?.invoke()
            }
        }
    }
    fun login(email: String, password: String) {
        retireAudio(); epoch = bridge.revoke(core)
        command(JSONObject().put("command", "login").put("email", email.trim()).put("password", password)) {
            if (snapshot.optBoolean("authenticated")) { saveCredentials(); library() }
        }
    }
    fun logout() {
        retireAudio(); epoch = bridge.revoke(core)
        getSharedPreferences("native-session", MODE_PRIVATE).edit().clear().commit()
        command(JSONObject().put("command", "logout"))
    }
    fun library(offset: Int = 0, query: String = "") {
        command(JSONObject().put("command", "library").put("offset", offset).put("query", query).put("sort", "added_at").put("order", "desc"))
    }
    fun select(id: Long) {
        retireAudio(); epoch = bridge.revoke(core)
        command(JSONObject().put("command", "select").put("track_id", id))
    }
    private fun applyAudio(effect: JSONObject) {
        if (effect.optString("action") == "load") lastEffectCached = effect.optBoolean("cached")
        when (effect.getString("action")) {
            "load" -> {
                retireAudio()
                val scope = effect.getLong("epoch"); val incarnation = effect.getLong("session")
                val next = MediaPlayer()
                player = next
                next.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                next.setOnPreparedListener {
                    if (epoch == scope && snapshot.optLong("session") == incarnation && player === next) {
                        playerReady = true
                        pendingSeekMs?.let {position -> next.seekTo(position,MediaPlayer.SEEK_CLOSEST)}
                        pendingSeekMs = null
                        if (wantsPlayback) startPlayer() else report("paused")
                    }
                }
                next.setOnSeekCompleteListener {lastSeekCompleted = nativePositionMs();report()}
                next.setOnErrorListener { _, _, _ -> nativeTerminalState="failed";report("failed"); true }
                next.setOnCompletionListener { nativeTerminalState="ended";report("ended") }
                try { next.setDataSource(effect.getString("path")); next.prepareAsync() }
                catch (_: Exception) { report("failed") }
            }
            "pause" -> { try { player?.pause() } catch (_: IllegalStateException) {}; abandonFocus() }
            "play" -> startPlayer()
            "seek" -> try { nativeTerminalState=null;if (playerReady) player?.seekTo(effect.getLong("position_ms"), MediaPlayer.SEEK_CLOSEST) else pendingSeekMs = effect.getLong("position_ms") } catch (_: IllegalStateException) { report("failed") }
            "stop" -> retireAudio()
        }
    }
    private fun startPlayer() {
        if (!wantsPlayback || !playerReady) return
        nativeTerminalState=null
        if (!focusHeld) focusHeld = audio.requestAudioFocus(focus) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        if (!focusHeld) { report("failed"); return }
        try { player?.start(); showNotification(); report() } catch (_: IllegalStateException) { report("failed") }
    }
    private fun abandonFocus() { if (focusHeld) { audio.abandonAudioFocusRequest(focus); focusHeld = false } }
    private fun retireAudio() {
        player?.setOnPreparedListener(null); player?.setOnErrorListener(null); player?.setOnCompletionListener(null)
        player?.release(); player = null; playerReady = false;pendingSeekMs = null;nativeTerminalState=null; abandonFocus()
        // MediaPlayer.release is the platform decoder retirement barrier. Cache
        // entries are not unlinked here and remain owned by the shared core.
    }
    private fun report(forced: String? = null) {
        if (forced=="failed" || forced=="ended") nativeTerminalState=forced
        if (pendingReports || busy > 0) return
        val p = player ?: return
        val terminal=forced ?: nativeTerminalState
        if (!playerReady && terminal != "failed") return
        try {
            val state = terminal ?: if (p.isPlaying) "playing" else "paused"
            val duration = if (state=="failed") snapshot.optLong("duration_ms") else p.duration.takeIf {it>0}?.toLong() ?: snapshot.optLong("duration_ms")
            val position = if (state=="failed") snapshot.optLong("position_ms") else p.currentPosition.coerceAtLeast(0).toLong()
            pendingReports = true
            command(JSONObject().put("command", "audio_report").put("epoch", epoch).put("session", snapshot.optLong("session"))
                .put("state", state).put("position_ms", position).put("duration_ms", duration)) { pendingReports = false }
        } catch (_: IllegalStateException) { if (forced == "failed") listener?.invoke(snapshot, "native_playback_failed") }
    }
    private fun updateSession() {
        val state = when (snapshot.optString("transport")) { "playing" -> PlaybackState.STATE_PLAYING; "preparing" -> PlaybackState.STATE_BUFFERING; "failed" -> PlaybackState.STATE_ERROR; else -> PlaybackState.STATE_PAUSED }
        session.setPlaybackState(PlaybackState.Builder().setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SEEK_TO)
            .setState(state, snapshot.optLong("position_ms"), if (state == PlaybackState.STATE_PLAYING) 1f else 0f).build())
        val track = snapshot.optJSONArray("queue")?.optJSONObject(0)?.optJSONObject("track")
        session.setMetadata(MediaMetadata.Builder().putString(MediaMetadata.METADATA_KEY_TITLE, track?.optString("title") ?: "SoundQ")
            .putString(MediaMetadata.METADATA_KEY_ARTIST, track?.optString("artist") ?: "").putLong(MediaMetadata.METADATA_KEY_DURATION, snapshot.optLong("duration_ms")).build())
        val identity = "${track?.optLong("id")}:${snapshot.optString("transport")}"
        if (foreground && identity != notificationIdentity) showNotification()
    }
    private fun showNotification() {
        if (!foreground) startService(Intent(this, PlaybackService::class.java))
        val playing = snapshot.optString("transport") == "playing"
        val action = if (playing) "pause" else "play"
        val pending = PendingIntent.getService(this, 1, Intent(this, PlaybackService::class.java).setAction(action), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val track = snapshot.optJSONArray("queue")?.optJSONObject(0)?.optJSONObject("track")
        notificationIdentity = "${track?.optLong("id")}:${snapshot.optString("transport")}"
        val notification = Notification.Builder(this, "playback").setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(track?.optString("title") ?: "SoundQ").setContentText(track?.optString("artist") ?: "")
            .setContentIntent(open).setOngoing(playing).addAction(Notification.Action.Builder(if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play, if (playing) "Pause" else "Play", pending).build())
            .setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken).setShowActionsInCompactView(0)).build()
        startForeground(41, notification); foreground = true
    }
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        return (store.getKey("soundq-native-preview-v1", null) as? SecretKey) ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("soundq-native-preview-v1", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    private fun saveCredentials() {
        val admitted = epoch
        worker.execute {
            val credentials = JSONObject(bridge.execute(core, admitted, "{\"command\":\"credentials\"}")).optJSONObject("credentials") ?: return@execute
            try {
                val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key())
                val encrypted = cipher.doFinal(credentials.toString().toByteArray(Charsets.UTF_8))
                main.post { if (epoch == admitted) getSharedPreferences("native-session", MODE_PRIVATE).edit()
                    .putString(endpoint + ":iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                    .putString(endpoint + ":data", Base64.encodeToString(encrypted, Base64.NO_WRAP)).commit() }
            } catch (_: Exception) { main.post { listener?.invoke(snapshot, "secure_storage_failed") } }
        }
    }
    private fun loadCredentials(): JSONObject? = try {
        val prefs = getSharedPreferences("native-session", MODE_PRIVATE)
        val iv = prefs.getString(endpoint + ":iv", null)
        val data = prefs.getString(endpoint + ":data", null)
        if (iv == null || data == null) null else {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
            JSONObject(String(cipher.doFinal(Base64.decode(data, Base64.NO_WRAP)), Charsets.UTF_8))
        }
    } catch (_: Exception) { null }
    override fun onDestroy() {
        main.removeCallbacks(tick); unregisterReceiver(noisy); retireAudio(); session.release()
        epoch = bridge.revoke(core); worker.execute { bridge.close(core) }; worker.shutdown()
        super.onDestroy()
    }
}
