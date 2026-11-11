package com.soundq.android.data.preferences

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class CrossfadePreferencesTest {
    private fun fixture(test:(File)->Unit) {
        val root=Files.createTempDirectory(File(System.getenv("TMPDIR")!!).toPath(),"crossfade-pref-").toFile()
        try {test(File(root,"preference.json"))}finally {root.deleteRecursively()}
    }
    @Test fun offDefaultAndAcceptedChoiceSurviveFreshOwner()=fixture {file->
        val a=CrossfadePreferences(file);assertNull(a.capture());a.load();assertEquals(0,a.state.value.seconds)
        assertTrue(a.setSeconds(a.capture()!!,5){true});assertEquals(5,a.state.value.seconds)
        val b=CrossfadePreferences(file);b.load();assertEquals(5,b.state.value.seconds);assertFalse(b.state.value.error)
        assertTrue(b.setSeconds(b.capture()!!,0){true});val c=CrossfadePreferences(file);c.load();assertEquals(0,c.state.value.seconds)
    }
    @Test fun staleRevokedAndOutOfRangeWritesDoNotChangeBytes()=fixture {file->
        val a=CrossfadePreferences(file);a.load();val old=a.capture()!!
        assertTrue(a.setSeconds(old,4){true});val bytes=file.readBytes()
        assertFalse(a.setSeconds(old,3){true});assertFalse(a.setSeconds(a.capture()!!,13){true});assertFalse(a.setSeconds(a.capture()!!,2){false})
        assertArrayEquals(bytes,file.readBytes());assertEquals(4,a.state.value.seconds)
    }
    @Test fun malformedFutureDuplicateAndForeignWritesRetainAcceptedChoice()=fixture {file->
        val a=CrossfadePreferences(file);a.load();assertTrue(a.setSeconds(a.capture()!!,3){true})
        for(raw in listOf("{}","{\"version\":2,\"crossfadeSeconds\":1}","{\"version\":1,\"crossfadeSeconds\":13}","{\"version\":1,\"crossfadeSeconds\":\"2\"}","{\"version\":1,\"crossfadeSeconds\":1,\"crossfadeSeconds\":2}")) {
            file.writeText(raw);a.load();assertTrue(a.state.value.error);assertEquals(3,a.state.value.seconds);assertNull(a.capture());assertEquals(raw,file.readText())
        }
    }
    @Test fun foreignMutationAndSymbolicLinkRefuseWithoutOverwrite()=fixture {file->
        val a=CrossfadePreferences(file);a.load();assertTrue(a.setSeconds(a.capture()!!,2){true});val capture=a.capture()!!
        file.writeText("foreign");assertFalse(a.setSeconds(capture,3){true});assertEquals("foreign",file.readText())
        file.delete();val target=File(file.parentFile,"foreign.json").apply{writeText("protected")};Files.createSymbolicLink(file.toPath(),target.toPath())
        a.load();assertTrue(a.state.value.error);assertEquals("protected",target.readText())
    }
}
