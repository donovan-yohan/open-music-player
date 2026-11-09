package com.soundq.android.playback.nativeengine

import com.soundq.android.data.device.AndroidAudioAccess
import com.soundq.android.data.device.AudioContentProof
import java.io.File

/** Actual source consumer. Only app-created stage paths cross NativeCallbackOwner's deleting boundary. */
internal class PhoneAudioStage(private val access: AndroidAudioAccess, private val directory: File) {
    fun prepare(locator: String, expected: AudioContentProof, current: () -> Boolean): File {
        check(current())
        val encoded = File.createTempFile("phone-encoded-", ".stage", directory)
        try {
            val observed = access.copy(locator, encoded, current)
            require(observed == expected) { "The audio file changed. Choose this file again." }
            // Android platform decoding covers M4A/AAC/FLAC where installed codecs support it.
            // Always use decoded extent for phone bookmarks, including tagged MP3/WAV/Opus.
            return AndroidPlatformAudioStage.decode(encoded, directory, current)
        } finally {
            // The encoded copy is no longer borrowed after synchronous platform decoder retirement.
            encoded.delete()
        }
    }
}
