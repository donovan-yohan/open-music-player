package com.soundq.android

import android.net.Uri
import android.os.Environment
import com.soundq.android.data.device.PhoneAudioRepository
import com.soundq.android.data.deviceaudio.DeviceAudio
import org.junit.Assert.assertTrue

/** All files access is the only route to phone audio. Journeys that list a test-owned MediaStore original need the
 * runner to allow it first (`appops set <package> MANAGE_EXTERNAL_STORAGE allow`); this then rescans and returns the
 * available Library row the audio index gives that MediaStore item. */
internal fun PhoneAudioRepository.awaitIndexed(item: Uri, valid: () -> Boolean = { true }, timeoutMs: Long = 60_000): DeviceAudio {
    assertTrue("Runner must allow all files access (appops MANAGE_EXTERNAL_STORAGE allow)", Environment.isExternalStorageManager())
    val suffix = "/audio/media/${android.content.ContentUris.parseId(item)}"
    fun row() = state.value.snapshot?.files?.singleOrNull { f -> f.available && f.aliases.any { it.locator.value.endsWith(suffix) } }
    refresh(valid)
    val deadline = System.nanoTime() + java.util.concurrent.TimeUnit.MILLISECONDS.toNanos(timeoutMs)
    var nextRefresh = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(10)
    while (System.nanoTime() < deadline) {
        row()?.let { return it }
        // A scan admitted before the item existed finishes without it; ask again rather than racing it.
        if (System.nanoTime() > nextRefresh && !state.value.refreshing) { refresh(valid); nextRefresh = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(10) }
        Thread.sleep(50)
    }
    return checkNotNull(row()) { "Audio index never listed $item: ${state.value.scan} ${state.value.message}" }
}
