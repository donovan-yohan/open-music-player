package com.soundq.android.data.originalimport

import com.soundq.android.data.device.PhoneAudioRepository
import com.soundq.android.data.deviceaudio.AccessState
import com.soundq.android.data.deviceaudio.ContentOwner
import com.soundq.android.data.deviceaudio.HistoryKey
import com.soundq.android.playback.PlaybackRef
import com.soundq.android.playback.nativeengine.OriginalAudioReadLease
import kotlinx.coroutines.runBlocking

internal fun ContentOwner.originalRef(): PlaybackRef.Device = PlaybackRef.Device(
    (key as HistoryKey.Device).id.value.toString(), revision.sha256, revision.byteLength, incarnation,
)

/** Only accepts a live phone catalog admission. Managed downloads/cache cannot supply this capability. */
internal class PhoneImportOriginals(private val phone: PhoneAudioRepository, private val version: () -> Long) {
    fun stamp(owner: ContentOwner): OriginalSourceStamp? = phone.importSourceStamp(owner.originalRef(), version())
    fun current(owner: ContentOwner): Boolean = stamp(owner) != null

    fun open(owner: ContentOwner, current: () -> Boolean): ImportOriginalRead? = runBlocking {
        val ref = owner.originalRef()
        val capturedAuthority = phone.sourceAuthority(ref)
        val row = phone.observed(ref) ?: return@runBlocking null
        val admission = phone.admit(row) ?: return@runBlocking null
        fun active() = current() && phone.current(admission.sessionVersion) &&
            phone.sourceAuthority(ref) == capturedAuthority && phone.observed(ref)?.owner == admission.row.owner
        if (!active()) return@runBlocking null
        val route = admission.row.aliases.first { it.state == AccessState.AVAILABLE }.locator.value
        // Upload borrows a separate descriptor. A declined/failed upload cannot retire current listening.
        phone.reserveImportedOriginal(admission, ::active)?.use {
            DescriptorImportRead(phone.platform.openOriginal(route, ::active, {}, admission.row.canonicalId))
        }
    }
}

/** Sample and advance together; two equal rows do not erase an observed permission transition. */
internal class OriginalAccessEpoch(private val denied: () -> Unit = {}) {
    private var epoch: Long = 1

    fun observe(storageAllowed: () -> Boolean): Long? {
        val started = synchronized(this) { epoch }
        val allowed = storageAllowed()
        return synchronized(this) {
            if (!allowed) {
                epoch = Math.addExact(epoch, 1)
                // This leaf records Enrich retirement before a new grant can be observed.
                // Neither this monitor nor the Enrich replace gate encloses platform IO.
                denied()
                null
            } else epoch.takeIf { it == started }
        }
    }
}

internal class DescriptorImportRead(private val lease: OriginalAudioReadLease) : ImportOriginalRead {
    override val length get() = lease.length
    override fun checkCurrent() = lease.checkCurrent()
    override fun readAt(position: Long, bytes: ByteArray, count: Int): Int {
        // The existing decoder read budget is per operation; total import bytes are bounded independently.
        lease.beginOperation()
        return lease.readAt(position, bytes, 0, count)
    }
    override fun close() = lease.close()
}
