package com.soundq.android.playback

import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** Source admission tracer; behavioral TLS callback probe is a separate gate. */
class LibraryContinuationWiringTest {
    @Test fun naturalCompletionIsBoundToTheSoleServicePlayer() {
        val source=File("src/main/kotlin/com/soundq/android/playback/SoundQLibraryService.kt").readText()
        assertTrue("Natural completion has no continuation listener",source.contains("ServiceLibraryContinuation("))
    }
}
