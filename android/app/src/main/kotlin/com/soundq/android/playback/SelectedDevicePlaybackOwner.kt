package com.soundq.android.playback

import com.soundq.android.data.deviceaudio.ContentRevision
import com.soundq.android.data.deviceaudio.DeviceFileId
import com.soundq.android.data.deviceaudio.DeviceListeningSnapshot
import java.util.UUID
import kotlinx.serialization.Serializable

/** Service-selected grant identity, not audio-read readiness or an account capability. */
@Serializable data class SelectedDevicePlaybackOwner(val occurrence:String,val ref:PlaybackRef.Device,val version:Long) {
    init {require(occurrence.isNotBlank()&&version>=0)}

    /** A failed read may revoke aliases/audioRevision while the exact source owner survives.
     * Replacement, removal and same-bytes incarnation ABA must still retire feedback. */
    internal fun retainedBy(snapshot:DeviceListeningSnapshot?):Boolean = runCatching {
        val id=UUID.fromString(ref.id)
        require(id.toString()==ref.id&&ref.incarnation>0)
        snapshot?.resolveRetained(DeviceFileId(id),ContentRevision(ref.sha256,ref.bytes),ref.incarnation)!=null
    }.getOrDefault(false)
}
