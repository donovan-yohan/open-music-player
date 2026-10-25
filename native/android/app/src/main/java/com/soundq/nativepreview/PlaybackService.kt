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
    // Native EOF truth outlives its one acknowledged final report.
    private var endedReportAcknowledged = false
    private lateinit var session: MediaSession
    private lateinit var audio: AudioManager
    private lateinit var focus: AudioFocusRequest
    private var focusHeld = false
    private var foreground = false
    private var notificationIdentity = ""
    private var wantsPlayback = false
    // Transport admission can change without replacing the selection/account.
    private var transportIntent = 0L
    private var pendingReports = false
    private var busy = 0
    // Account intent, not playback selection, owns delayed private storage.
    private var credentialEpoch = 1L
    private var storedCredentialVersion = 0L
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
        core = bridge.open(endpoint, File(filesDir, "client-data-v1").absolutePath)
        check(core != 0L) {"Application core configuration refused"}
        audio = getSystemService(AudioManager::class.java)
        focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setOnAudioFocusChangeListener({ change ->
                when (change) {
                    AudioManager.AUDIOFOCUS_LOSS,
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                        abandonFocus()
                        command(JSONObject().put("command", "pause"))
                    }
                }
                // No automatic replay after focus loss. User explicitly resumes.
            }, main).build()
        session = MediaSession(this, "SoundQNative")
        session.setCallback(object : MediaSession.Callback() {
            override fun onPlay() { command(JSONObject().put("command", "resume")) }
            override fun onPause() { command(JSONObject().put("command", "pause")) }
            override fun onSeekTo(pos: Long) { lastSeekRequested = pos;command(JSONObject().put("command", "seek").put("position_ms", pos)) }
            override fun onStop() { command(JSONObject().put("command", "pause")) }
            override fun onSkipToNext() { queueAction("next") }
            override fun onSkipToPrevious() { queueAction("previous") }
        }, main)
        session.isActive = true
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("playback", "Playback", NotificationManager.IMPORTANCE_LOW))
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(noisy, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), RECEIVER_NOT_EXPORTED)
        else registerReceiver(noisy, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        main.post(tick)
        val saved = loadCredentials()
        if (saved != null) command(saved.put("command", "restore")) {command(JSONObject().put("command","queue_restore")) {library()}}
        else command(JSONObject().put("command", "snapshot"))
    }
    override fun onBind(intent: Intent): IBinder = binder
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "pause" -> command(JSONObject().put("command", "pause"))
            "play" -> command(JSONObject().put("command", "resume"))
        }
        // A delayed no-action start cannot revive a paused/cancelled intent.
        if (!wantsPlayback) stopPlaybackService()
        return START_NOT_STICKY
    }
    fun command(value: JSONObject, done: (() -> Unit)? = null) {
        val kind = value.optString("command")
        if (kind == "restore") value.remove("version")
        if (kind in listOf("login", "register", "restore", "logout")) {
            credentialEpoch++
            storedCredentialVersion = 0L
            if (kind != "restore") getSharedPreferences("native-session", MODE_PRIVATE).edit().clear().commit()
        }
        // Pause cancels an undelivered EOF, but must not erase a real native
        // failure or turn an already acknowledged Ended into periodic Paused.
        if (kind == "pause" && nativeTerminalState == "ended" && !endedReportAcknowledged) nativeTerminalState = null
        if (kind in listOf("pause","queue_clear","queue_restore","logout","login","register","restore")) {transportIntent++;wantsPlayback = false;if (kind != "pause") {nativeTerminalState=null;endedReportAcknowledged=false};if (playerReady) {try {player?.pause()} catch (_: IllegalStateException) {}};abandonFocus();stopPlaybackService()}
        // Local pause is synchronous even under pressure; the next native
        // report reconciles paused state if core command admission is full.
        if (busy >= 32) {listener?.invoke(snapshot,"command_backpressure");return}
        val playbackRequest = kind in listOf("select","queue_play","next","previous","resume","retry") || kind=="queue_remove" && value.optLong("occurrence_id",-1)==snapshot.optLong("selected_occurrence",-2)
        if (playbackRequest) {
            // This is the explicit UI/MediaSession/notification intent, before
            // download or decoder preparation can outlive foreground eligibility.
            transportIntent++
            nativeTerminalState = null
            endedReportAcknowledged = false
            wantsPlayback = true
            try {
                if (!foreground) startForegroundService(Intent(this, PlaybackService::class.java))
                showNotification()
            } catch (_: RuntimeException) {failPlayback();return}
        }
        val admitted = epoch
        val admittedAccount = credentialEpoch
        val admittedIntent = transportIntent
        val admittedPlayer = player
        val admittedTerminal = nativeTerminalState
        val raw = value.put("account_scope_v1", admittedAccount).toString()
        busy++
        worker.execute {
            val result = try { JSONObject(bridge.execute(core, admitted, raw)) } catch (_: Exception) { JSONObject().put("ok", false).put("code", "binding_failure") }
            main.post {
                busy--
                try {
                    if (admitted != epoch || admittedAccount != credentialEpoch) return@post
                    val next = result.optJSONObject("snapshot")
                    val effect = result.optJSONObject("audio")
                    // A retired final observation has nothing left to publish.
                    // An accepted nonfinal EOF also owns decoder replacement:
                    // Pause/Resume may change intent, not that selection's load.
                    val continuationLoad = kind == "audio_report" && value.optString("state") == "ended" &&
                        player === admittedPlayer && value.optLong("session",-1) == snapshot.optLong("session") &&
                        next != null && next.optLong("epoch") == epoch && next.optString("transport") == "preparing" &&
                        next.optLong("selected_occurrence",0) > 0 && next.optLong("session",-1) != value.optLong("session",-1) &&
                        effect != null && effect.optString("action") == "load" && effect.optString("path").isNotEmpty() &&
                        effect.optLong("epoch") == epoch && effect.optLong("session",-1) == next.optLong("session") &&
                        (result.optBoolean("ok") || result.optString("code") in listOf("invalid_saved_queue","queue_storage_failed","cache_io"))
                    if (kind == "audio_report" && value.optString("state") == "ended" && admittedTerminal == "ended" &&
                        !continuationLoad && (admittedIntent != transportIntent || player !== admittedPlayer || nativeTerminalState != "ended")) {
                        // Retired observation cannot publish or acknowledge, but
                        // account delivery and this request's cleanup still apply.
                        result.optJSONObject("credentials")?.let {saveCredentials(it)}
                        done?.invoke()
                        return@post
                    }
                    if (next != null && next.optLong("epoch") == epoch) {
                        // Consume only applied current final EOF, before listener
                        // reentrancy can create another observation/intent. A local
                        // save fault acknowledges decoder truth, not durability;
                        // its original failure is still published below.
                        if (kind == "audio_report" && value.optString("state") == "ended" &&
                            admittedIntent == transportIntent && nativeTerminalState == "ended" &&
                            value.optLong("session",-1) == snapshot.optLong("session") &&
                            next.optLong("session",-1) == snapshot.optLong("session") &&
                            next.optLong("selected_occurrence",0) == snapshot.optLong("selected_occurrence",0) &&
                            next.optString("transport") == "ended" && result.optJSONObject("audio") == null &&
                            (result.optBoolean("ok") || result.optString("code") in listOf("invalid_saved_queue","queue_storage_failed","cache_io"))) {
                            endedReportAcknowledged = true
                            // Release this EOF's ownership before notifying a
                            // listener that may synchronously seek or resume.
                            wantsPlayback=false;abandonFocus();stopPlaybackService()
                        }
                        if (next.optBoolean("library_unchanged")) next.put("library",snapshot.optJSONArray("library") ?: org.json.JSONArray())
                        if (next.optBoolean("queue_unchanged")) next.put("queue",snapshot.optJSONArray("queue") ?: org.json.JSONArray())
                        snapshot = next
                        listener?.invoke(snapshot, if (result.optBoolean("ok")) null else result.optString("code"))
                    } else if (!result.optBoolean("ok")) listener?.invoke(snapshot, result.optString("code"))
                    // Listener callbacks may synchronously change any intent.
                    if (admitted != epoch || admittedAccount != credentialEpoch) return@post
                    // Command failure and decoder authority are independent only
                    // for a local queue-save fault with a coherent current effect.
                    val retainedPlayback = result.optString("code") in listOf("invalid_saved_queue","queue_storage_failed","cache_io") &&
                        next != null && next.optLong("epoch") == epoch && snapshot === next &&
                        next.optString("transport") == "preparing" && next.optLong("selected_occurrence",0) > 0 &&
                        effect != null && effect.optLong("epoch") == epoch && effect.optLong("session",-1) == next.optLong("session") &&
                        (effect.optString("action") == "play" || effect.optString("action") == "load" && effect.optString("path").isNotEmpty())
                    if (admittedIntent == transportIntent && !result.optBoolean("ok") && playbackRequest && !retainedPlayback) {wantsPlayback=false;try {player?.pause()} catch (_: IllegalStateException) {};abandonFocus();stopPlaybackService()}
                    if (kind=="audio_report" && value.optString("state")=="ended" && !endedReportAcknowledged && admittedIntent==transportIntent && result.optJSONObject("audio")==null) {
                        transportIntent++;wantsPlayback=false;abandonFocus();stopPlaybackService()
                    }
                    result.optJSONObject("audio")?.let {
                        // Preparation still belongs to this selection after Pause.
                        // Other effects cannot retire a newer foreground admission.
                        if ((result.optBoolean("ok") || !playbackRequest || retainedPlayback) && it.optLong("epoch") == epoch && (admittedIntent == transportIntent || it.optString("action") == "load")) applyAudio(it)
                    }
                    // Transport cancellation never revokes account credential delivery.
                    result.optJSONObject("credentials")?.let {saveCredentials(it)}
                    updateSession()
                    done?.invoke()
                } finally {
                    // Cleanup belongs to this request, even after selection/account
                    // retirement. Only one audio report can be pending at a time.
                    if (kind == "audio_report") pendingReports = false
                }
            }
        }
    }
    fun login(email: String, password: String) {
        retireAudio(); epoch = bridge.revoke(core)
        command(JSONObject().put("command", "login").put("email", email.trim()).put("password", password)) {
            if (snapshot.optBoolean("authenticated")) library()
        }
    }
    fun logout() {
        retireAudio(); epoch = bridge.revoke(core)
        command(JSONObject().put("command", "logout"))
    }
    fun library(offset: Int = 0, query: String = "") {
        command(JSONObject().put("command", "library").put("offset", offset).put("query", query).put("sort", "added_at").put("order", "desc"))
    }
    fun select(id: Long) {
        wantsPlayback=false;retireAudio(); epoch = bridge.revoke(core)
        command(JSONObject().put("command", "select").put("track_id", id))
    }
    fun selectedTrack(): JSONObject? {
        val values=snapshot.optJSONArray("queue") ?: return null
        val selected=snapshot.optLong("selected_occurrence",-1)
        return (0 until values.length()).firstOrNull {values.getJSONObject(it).optLong("id")==selected}?.let {values.getJSONObject(it).optJSONObject("track")}
    }
    fun queueAction(kind:String,id:Long?=null,index:Int?=null) {
        val selected=snapshot.optLong("selected_occurrence",-1)
        val values=snapshot.optJSONArray("queue")
        val current=(0 until (values?.length() ?: 0)).firstOrNull {values!!.getJSONObject(it).optLong("id")==selected}
        if (kind=="next" && (current==null || current+1>=(values?.length() ?: 0))) return
        if (kind=="previous" && (current==null || current==0)) return
        val changesSelection=kind in listOf("queue_play","next","previous","queue_clear") || kind=="queue_remove" && id==selected
        if (busy >= 32) {listener?.invoke(snapshot,"command_backpressure");return}
        if (changesSelection) {transportIntent++;wantsPlayback=false;retireAudio();epoch=bridge.revoke(core)}
        val value=JSONObject().put("command",kind)
        if(id!=null)value.put(if(kind=="queue_append") "track_id" else "occurrence_id",id)
        if(index!=null)value.put("to_index",index)
        command(value)
    }
    private fun applyAudio(effect: JSONObject) {
        if (effect.optString("action") == "load") lastEffectCached = effect.optBoolean("cached")
        when (effect.getString("action")) {
            "load" -> {
                val continuing = nativeTerminalState=="ended" && wantsPlayback
                retireAudio(keepForeground = wantsPlayback, clearTerminal = continuing)
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
                pendingSeekMs=effect.optLong("position_ms").takeIf {it>0}
                next.setOnSeekCompleteListener {if(player===next && epoch==scope && snapshot.optLong("session")==incarnation){lastSeekCompleted = nativePositionMs();report()}}
                next.setOnErrorListener { _, _, _ -> if(player===next && epoch==scope && snapshot.optLong("session")==incarnation) failPlayback(); true }
                // Continue only the still-admitted foreground intent. EOF does
                // not start a service or acquire a new foreground admission.
                next.setOnCompletionListener {if(player===next && epoch==scope && snapshot.optLong("session")==incarnation && wantsPlayback && nativeTerminalState==null){nativeTerminalState="ended";report("ended")}}
                try { next.setDataSource(effect.getString("path")); next.prepareAsync() }
                catch (_: Exception) { failPlayback() }
            }
            "pause" -> { if (playerReady) {try { player?.pause() } catch (_: IllegalStateException) {}}; abandonFocus();stopPlaybackService() }
            "play" -> startPlayer()
            "seek" -> if (nativeTerminalState != "failed") try { nativeTerminalState=null;endedReportAcknowledged=false;if (playerReady) player?.seekTo(effect.getLong("position_ms"), MediaPlayer.SEEK_CLOSEST) else pendingSeekMs = effect.getLong("position_ms") } catch (_: IllegalStateException) { report("failed") }
            "stop" -> retireAudio(clearTerminal = false)
        }
    }
    private fun startPlayer() {
        if (!wantsPlayback || !playerReady) return
        try {
            // Never acquire focus or start a decoder without admitted foreground
            // ownership. A delayed callback cannot start/retry the service.
            check(foreground)
            showNotification()
            if (!focusHeld) focusHeld = audio.requestAudioFocus(focus) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            if (!focusHeld) {failPlayback();return}
            nativeTerminalState=null
            endedReportAcknowledged=false
            player?.start();report()
        } catch (_: RuntimeException) {failPlayback()}
    }
    private fun stopPlaybackService() {
        if (foreground) {stopForeground(STOP_FOREGROUND_REMOVE);foreground=false}
        stopSelf()
    }
    private fun failPlayback() {
        transportIntent++
        wantsPlayback=false
        try {player?.pause()} catch (_: IllegalStateException) {}
        abandonFocus();stopPlaybackService();report("failed")
    }
    private fun abandonFocus() { if (focusHeld) { audio.abandonAudioFocusRequest(focus); focusHeld = false } }
    private fun retireAudio(keepForeground: Boolean = false, clearTerminal: Boolean = true) {
        player?.setOnPreparedListener(null); player?.setOnErrorListener(null); player?.setOnCompletionListener(null);player?.setOnSeekCompleteListener(null)
        player?.release(); player = null; playerReady = false;pendingSeekMs = null;if (clearTerminal) {nativeTerminalState=null;endedReportAcknowledged=false}; abandonFocus()
        if (!keepForeground) stopPlaybackService()
        // MediaPlayer.release is the platform decoder retirement barrier. Cache
        // entries are not unlinked here and remain owned by the shared core.
    }
    private fun report(forced: String? = null) {
        if (forced=="failed" || forced=="ended") {if (nativeTerminalState!=forced) endedReportAcknowledged=false;nativeTerminalState=forced}
        if (pendingReports || busy > 0) return
        val p = player
        val terminal=nativeTerminalState ?: forced
        if (terminal == "ended" && endedReportAcknowledged) return
        if (p == null && terminal != "failed") return
        if (!playerReady && terminal != "failed") return
        try {
            val state = terminal ?: if (p?.isPlaying == true) "playing" else "paused"
            val duration = if (state=="failed") snapshot.optLong("duration_ms") else p?.duration?.takeIf {it>0}?.toLong() ?: snapshot.optLong("duration_ms")
            val position = if (state=="failed") snapshot.optLong("position_ms") else p?.currentPosition?.coerceAtLeast(0)?.toLong() ?: 0L
            pendingReports = true
            command(JSONObject().put("command", "audio_report").put("epoch", epoch).put("session", snapshot.optLong("session"))
                .put("state", state).put("position_ms", position).put("duration_ms", duration)) { pendingReports = false }
        } catch (_: IllegalStateException) { if (forced == "failed") listener?.invoke(snapshot, "native_playback_failed") }
    }
    private fun updateSession() {
        val state = when (snapshot.optString("transport")) { "playing" -> PlaybackState.STATE_PLAYING; "preparing" -> PlaybackState.STATE_BUFFERING; "failed" -> PlaybackState.STATE_ERROR; else -> PlaybackState.STATE_PAUSED }
        session.setPlaybackState(PlaybackState.Builder().setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SEEK_TO or PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS)
            .setState(state, snapshot.optLong("position_ms"), if (state == PlaybackState.STATE_PLAYING) 1f else 0f).build())
        val track = selectedTrack()
        session.setMetadata(MediaMetadata.Builder().putString(MediaMetadata.METADATA_KEY_TITLE, track?.optString("title") ?: "SoundQ")
            .putString(MediaMetadata.METADATA_KEY_ARTIST, track?.optString("artist") ?: "").putLong(MediaMetadata.METADATA_KEY_DURATION, snapshot.optLong("duration_ms")).build())
        val identity = "${track?.optLong("id")}:${snapshot.optString("transport")}"
        if (foreground && identity != notificationIdentity) try {showNotification()} catch (_: RuntimeException) {failPlayback()}
    }
    private fun showNotification() {
        val playing = snapshot.optString("transport") == "playing"
        val action = if (playing) "pause" else "play"
        val pending = if (playing) PendingIntent.getService(this, 1, Intent(this, PlaybackService::class.java).setAction(action), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            else PendingIntent.getForegroundService(this, 1, Intent(this, PlaybackService::class.java).setAction(action), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val track = selectedTrack()
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
    private fun saveCredentials(credentials: JSONObject) {
        val admitted = credentialEpoch
        val version = credentials.optLong("version")
        if (version <= 0 || version < storedCredentialVersion) return
        if (version == storedCredentialVersion) {
            command(JSONObject().put("command", "acknowledge_credentials").put("version", version))
            return
        }
        worker.execute {
            try {
                val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key())
                val encrypted = cipher.doFinal(credentials.toString().toByteArray(Charsets.UTF_8))
                main.post {
                    if (credentialEpoch != admitted || version < storedCredentialVersion) return@post
                    val saved = getSharedPreferences("native-session", MODE_PRIVATE).edit()
                        .putString(endpoint + ":iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                        .putString(endpoint + ":data", Base64.encodeToString(encrypted, Base64.NO_WRAP)).commit()
                    if (saved) {
                        storedCredentialVersion = version
                        command(JSONObject().put("command", "acknowledge_credentials").put("version", version))
                    } else listener?.invoke(snapshot, "secure_storage_failed")
                }
            } catch (_: Exception) { main.post { if (credentialEpoch == admitted) listener?.invoke(snapshot, "secure_storage_failed") } }
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
        credentialEpoch++
        main.removeCallbacks(tick); unregisterReceiver(noisy); retireAudio(); session.release()
        epoch = bridge.revoke(core); worker.execute { bridge.close(core) }; worker.shutdown()
        super.onDestroy()
    }
}
