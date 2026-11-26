package com.soundq.android.playback.nativeengine

import androidx.media3.common.MediaItem
import com.soundq.android.AppGraph
import com.soundq.android.data.SafeFailure
import com.soundq.android.data.deviceaudio.ServerAccount
import com.soundq.android.data.originalimport.DescriptorImportRead
import com.soundq.android.data.originalimport.OriginalAssociation
import com.soundq.android.data.originalimport.OriginalContentMismatch
import com.soundq.android.data.originalimport.originalPlayback
import com.soundq.android.data.originalimport.originalRef
import com.soundq.android.data.originalimport.verifyBytes
import com.soundq.android.playback.MediaGrant
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.runBlocking

/** Ordinary server occurrences keep their numeric identity. Only source acquisition borrows the
 * verified original. Arrangement/finite-file and explicit SoundQ downloads retain their old owners. */
internal class OriginalAwareNativeSource(
    private val graph: AppGraph,
    private val grants: ConcurrentHashMap<String, MediaGrant>,
) : GrantedNativeCallbackSource(graph, grants) {
    override fun acquire(item: MediaItem, current: () -> Boolean): NativePlaybackSource {
        val uri = item.localConfiguration?.uri.toString()
        val permit = grants[uri] ?: throw SafeFailure(SafeFailure.Reason.Retired)
        val explicit = item.mediaMetadata.extras?.getString("originalImportOperation")
        if ((explicit != null || permit.originalOnly) && (!graph.originalImports.enabled || explicit == null || permit.device != null))
            throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
        if (permit.device != null) return super.acquire(item, current)
        permit.phoneAdmission = null // Numeric queue identity can acquire different playback custody on a new admission.
        if (!graph.originalImports.enabled) return super.acquire(item, current)
        check(current() && permit.current(graph))
        val scope = permit.scope
        return originalPlayback(ServerAccount(graph.endpoint.identity, scope.accountId), permit.track, explicit, permit.localOnly,
            { if (explicit != null) graph.originalImports.admitExplicitOriginal(scope, permit.track, explicit)
                else graph.originalImports.admitOnlinePlayback(scope, permit.track) },
            { graph.phoneAudio.importSourceStamp(it.intent.original.originalRef(), permit.version) != null },
            { openOriginal(it, uri, permit, current) }, { super.acquire(item, current) })
    }

    private fun openOriginal(binding: OriginalAssociation, uri: String, permit: MediaGrant, current: () -> Boolean): NativePlaybackSource {
        val scope = permit.scope
        val ref = binding.intent.original.originalRef()
        val sourceCurrent = graph.phoneAudio.borrowOriginalCurrent(ref, permit.version) ?: throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
        val row = graph.phoneAudio.observed(ref) ?: throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
        fun active() = current() && grants[uri] === permit && permit.current(graph) && graph.originalImports.owns(scope, binding) &&
            sourceCurrent()
        // Once an exact original was selected, any custody failure is terminal for this acquisition.
        // A subsequent ordinary online action can use server storage if the original is no longer available.
        return try {
            runBlocking {
                check(active())
                val admission = graph.phoneAudio.admit(row) ?: throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
                // Delete observes the physical grant even while decoder acquisition is pending.
                permit.phoneAdmission = admission
                val reservation = graph.phoneAudio.reserveImportedOriginal(admission, ::active)
                    ?: throw SafeFailure(SafeFailure.Reason.Retired)
                val (source, accepted) = try {
                    reservation.use {
                        graph.phoneAudio.openOriginal(admission, verify = { lease ->
                            verifyBytes(DescriptorImportRead(lease), binding.intent.original.revision, ::active)
                        }, valid = ::active)
                    }
                } catch (changed: OriginalContentMismatch) {
                    if (active()) graph.phoneAudio.reportFailure(admission, changed)
                    throw changed
                }
                if (!active()) {
                    source.release()
                    throw SafeFailure(SafeFailure.Reason.Retired)
                }
                permit.phoneAdmission = accepted
                source
            }
        } catch (retired: java.util.concurrent.CancellationException) {
            if (current() && grants[uri] === permit && permit.current(graph)) throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
            throw retired
        }
    }
}
