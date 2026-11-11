package com.soundq.android.data.preferences

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path

class EndOfQueuePreferencesTest {
    private fun fixture(test:(java.io.File)->Unit) {val dir=Files.createTempDirectory(Path.of(System.getenv("TMPDIR")),"end-queue-").toFile();try {test(dir.resolve("mode.json"))}finally {dir.deleteRecursively()}}
    @Test fun defaultsAndBothAcceptedModesSurviveReconstruction()=fixture {file->
        val p=EndOfQueuePreferences(file);p.load();assertEquals(EndOfQueue.ShuffleLibrary,p.state.value.mode);assertFalse(file.exists())
        assertTrue(p.setMode(p.capture()!!,EndOfQueue.Off){true});val read=EndOfQueuePreferences(file);read.load();assertEquals(EndOfQueue.Off,read.state.value.mode)
        assertTrue(read.setMode(read.capture()!!,EndOfQueue.ShuffleLibrary){true});val again=EndOfQueuePreferences(file);again.load();assertEquals(EndOfQueue.ShuffleLibrary,again.state.value.mode)
    }
    @Test fun strictRejectedValuesArePreservedAndUnwritable()=fixture {file->
        for(raw in listOf("{}","""{"version":1,"endOfQueue":"radio"}""","""{"version":"1","endOfQueue":"off"}""","""{"version":1,"endOfQueue":false}""","""{"version":2,"endOfQueue":"off"}""","""{"version":1,"endOfQueue":"off","keepQueued":true}""")) {
            file.writeText(raw);val p=EndOfQueuePreferences(file);p.load();assertTrue(p.state.value.error);assertNull(p.capture());assertEquals(raw,file.readText())
        }
    }
    @Test fun staleCaptureRouteExitAndChangedDiskCannotOverwriteAcceptedChoice()=fixture {file->
        val p=EndOfQueuePreferences(file);p.load();val old=p.capture()!!
        assertFalse(p.setMode(old,EndOfQueue.Off){false});assertFalse(file.exists());assertTrue(p.setMode(old,EndOfQueue.Off){true});assertFalse(p.setMode(old,EndOfQueue.ShuffleLibrary){true})
        val current=p.capture()!!;file.writeText("foreign bytes");assertFalse(p.setMode(current,EndOfQueue.ShuffleLibrary){true});assertEquals("foreign bytes",file.readText());assertEquals(EndOfQueue.Off,p.state.value.mode)
    }
    @Test fun symlinkNeverReplacesTargetOrPublishesAChoice()=fixture {file->
        val target=file.resolveSibling("target");target.writeText("secret");Files.createSymbolicLink(file.toPath(),target.toPath());val p=EndOfQueuePreferences(file);p.load();assertNull(p.capture());assertEquals("secret",target.readText())
    }
}
