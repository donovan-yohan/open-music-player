package com.soundq.android.playback

import java.io.File
import java.util.UUID

internal const val DISCOVERY_PREVIEW_PREFIX = "discovery-preview:"

internal class PreviewLifetime(private val mainCurrent: () -> Boolean, val wireCurrent: () -> Boolean) : () -> Boolean {
    override fun invoke() = mainCurrent()
}

/** In-process only: no preview capability crosses MediaSession IPC. */
internal fun interface DiscoveryPreviewHandoff {
    suspend fun prepare(scope: com.soundq.android.data.AccountScope, source: com.soundq.android.data.imports.ImportSource,
        title: String, artist: String, current: PreviewLifetime): Boolean
}

/** A one-shot local command capability. The frozen source guard is revoked monotonically.
 * This owns admission/staging only. The service Player remains the sole live queue owner. */
internal class ContextStartAdmission(private val directory:File) {
    init {
        // Tickets are process-local capabilities, never a restart command journal.
        // Reclaim only this feature's abandoned staging, not the durable queue.
        directory.listFiles()?.forEach {it.deleteRecursively()}
    }
    internal class Capture internal constructor(val ticket:String,val endpoint:String,val account:String,private val source:()->Boolean) {
        @Volatile private var live=true
        @Volatile private var claimed=false
        fun current():Boolean {if(live && !source())live=false;return live}
        internal fun revoke(){live=false}
        @Synchronized internal fun claim():Boolean {if(claimed || !current())return false;claimed=true;return true}
    }
    @Volatile private var active:Capture?=null
    @Volatile private var generation=0L
    // Service attach, detach and preview handoff are all confined to the main looper.
    @Volatile internal var discoveryPreview: DiscoveryPreviewHandoff? = null
    internal suspend fun startDiscoveryPreview(scope: com.soundq.android.data.AccountScope,
        source: com.soundq.android.data.imports.ImportSource, title: String, artist: String, valid: () -> Boolean,
        wireValid: () -> Boolean = { true }): Boolean {
        val target = discoveryPreview ?: return false
        val revision = generation
        fun wireCurrent() = discoveryPreview === target && generation == revision && wireValid()
        fun current() = wireCurrent() && valid()
        if (!current()) return false
        return target.prepare(scope, source, title, artist, PreviewLifetime(::current, ::wireCurrent)).also { if (it && current()) retire() }
    }
    /** Reserve before asynchronous metadata IO. Retirement is remembered even
     * without a staged ticket. This guard ends at the synchronous ticket handoff;
     * do not retain it as that ticket's source guard, since capture supersedes it. */
    @Synchronized fun captureRead():()->Boolean {
        retire()
        val revision=generation
        return {generation==revision}
    }
    @Synchronized fun capture(endpoint:String,account:String,current:()->Boolean):Capture {
        retire()
        return Capture(UUID.randomUUID().toString(),endpoint,account,current).also {active=it}
    }
    fun current(c:Capture)=active===c && c.current()
    private fun store(c:Capture)=QueueSnapshotStore(File(directory,c.ticket+".json"))
    fun stage(c:Capture,saved:QueueSnapshot) {
        require(saved.endpoint==c.endpoint && saved.account==c.account)
        store(c).write(saved){current(c)}
    }
    @Synchronized fun claim(ticket:String):Capture?=active?.takeIf {it.ticket==ticket && it.claim()}
    fun read(c:Capture)=store(c).read(c.endpoint,c.account){current(c)}
    fun finish(c:Capture) {synchronized(this){c.revoke();if(active===c)active=null};store(c).delete()}
    @Synchronized fun retire(){generation++;active?.revoke();active=null}
}
