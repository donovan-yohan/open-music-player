package com.soundq.android.data.preferences

import com.soundq.android.data.*
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class KeyNotationPreferencesTest {
    private fun withFile(block:(java.io.File)->Unit) {
        val dir=Files.createTempDirectory("key-notation").toFile()
        try {block(dir.resolve("key-notation.v1.json"))}finally {dir.deleteRecursively()}
    }
    @Test fun absentDefaultsAndBothChoicesRoundTripStableWireBytes()=withFile {file->
        val owner=KeyNotationPreferences(file)
        assertFalse(owner.state.value.ready);assertNull(owner.capture());owner.load()
        assertEquals(KeyNotation.Camelot,owner.state.value.choice);assertFalse(file.exists())
        for(choice in KeyNotation.entries) {
            assertTrue(owner.setChoice(owner.capture()!!,choice){true})
            assertEquals("{\"version\":1,\"keyNotation\":\"${choice.wire}\"}",file.readText())
            val restored=KeyNotationPreferences(file);restored.load()
            assertEquals(choice,restored.state.value.choice);assertTrue(restored.state.value.ready)
            assertNull(restored.state.value.error);assertNotNull(restored.capture())
        }
    }
    @Test fun rejectedFutureOversizedAndUnreadableFilesKeepAcceptedChoiceAndCannotWrite()=withFile {file->
        val owner=KeyNotationPreferences(file);owner.load()
        assertTrue(owner.setChoice(owner.capture()!!,KeyNotation.Musical){true})
        for(raw in listOf("", "broken", "{\"version\":2,\"keyNotation\":\"camelot\"}",
            "{\"version\":1,\"keyNotation\":\"future\"}", "{\"version\":\"1\",\"keyNotation\":\"musical\"}",
            "{\"version\":1,\"keyNotation\":1}", "{\"version\":1,\"keyNotation\":\"Camelot\"}",
            "{\"version\":1,\"keyNotation\":\"camelot\",\"extra\":true}", " ".repeat(4097))) {
            val old=owner.capture();file.writeText(raw);owner.load()
            assertEquals(KeyNotation.Musical,owner.state.value.choice)
            assertEquals(KeyNotationError.Read,owner.state.value.error);assertNull(owner.capture())
            if(old!=null)assertFalse(owner.setChoice(old,KeyNotation.Camelot){true})
            val fresh=KeyNotationPreferences(file);fresh.load();assertEquals(KeyNotation.Camelot,fresh.state.value.choice)
            assertNull(fresh.capture());assertEquals(raw,file.readText())
        }
        file.delete();file.mkdir();owner.load();assertNull(owner.capture());assertTrue(file.isDirectory)
        file.delete();val target=file.parentFile!!.resolve("foreign").also {it.writeText("private")}
        Files.createSymbolicLink(file.toPath(),target.toPath());owner.load()
        assertNull(owner.capture());assertEquals("private",target.readText());Files.delete(file.toPath())
        file.writeText("{\"version\":1,\"keyNotation\":\"camelot\"}");owner.load()
        assertEquals(KeyNotation.Camelot,owner.state.value.choice);assertNull(owner.state.value.error)
        assertTrue(owner.setChoice(owner.capture()!!,KeyNotation.Musical){true})
    }
    @Test fun foreignOwnerRevisionAndReloadCapturesAreRefusedWithoutChangingBytes()=withFile {file->
        val a=KeyNotationPreferences(file);val b=KeyNotationPreferences(file.parentFile!!.resolve("other"));a.load();b.load()
        assertFalse(a.setChoice(b.capture()!!,KeyNotation.Musical){true});assertFalse(file.exists())
        val initial=a.capture()!!;a.load()
        assertFalse(a.setChoice(initial,KeyNotation.Musical){true})
        val old=a.capture()!!;assertTrue(a.setChoice(old,KeyNotation.Musical){true});val accepted=file.readBytes()
        assertFalse(a.setChoice(old,KeyNotation.Camelot){true});assertArrayEquals(accepted,file.readBytes())
    }
    @Test fun externallyReplacedBytesRequireExplicitReloadWithoutOverwrite()=withFile {file->
        val owner=KeyNotationPreferences(file);owner.load()
        assertTrue(owner.setChoice(owner.capture()!!,KeyNotation.Musical){true})
        for(raw in listOf("{\"version\":99,\"keyNotation\":\"camelot\"}","{\"version\":1,\"keyNotation\":\"camelot\"}")) {
            val capture=owner.capture()!!;file.writeText(raw)
            assertFalse(owner.setChoice(capture,KeyNotation.Musical){true})
            assertEquals(raw,file.readText());assertNull(owner.capture())
            assertEquals(KeyNotation.Musical,owner.state.value.choice)
            owner.load()
            if(owner.capture()==null){file.writeText("{\"version\":1,\"keyNotation\":\"musical\"}");owner.load()}
        }
        assertEquals(KeyNotation.Camelot,owner.state.value.choice)
        assertTrue(file.parentFile!!.listFiles()!!.none {it.name.endsWith(".new")})
    }
    @Test fun failedSaveDoesNotPublishOrReplayAndExplicitRetryRecovers()=withFile {file->
        val parent=file.parentFile!!.resolve("blocked");parent.writeText("keep")
        val path=parent.resolve("notation");val owner=KeyNotationPreferences(path);owner.load()
        val capture=owner.capture()!!
        assertFalse(owner.setChoice(capture,KeyNotation.Musical){true})
        assertEquals(KeyNotation.Camelot,owner.state.value.choice);assertEquals(KeyNotationError.Write,owner.state.value.error)
        parent.delete();parent.mkdir();assertFalse(path.exists())
        assertFalse(owner.setChoice(capture,KeyNotation.Musical){true});assertFalse(path.exists())
        assertTrue(owner.setChoice(owner.capture()!!,KeyNotation.Musical){true})
        assertEquals(KeyNotation.Musical,owner.state.value.choice);assertNull(owner.state.value.error)
    }
    @Test fun replacementDuringStagingCannotBeOverwrittenAndMalformedUtf8CannotGrantAuthority()=withFile {file->
        val owner=KeyNotationPreferences(file);owner.load()
        assertTrue(owner.setChoice(owner.capture()!!,KeyNotation.Musical){true})
        val foreign="{\"version\":2,\"keyNotation\":\"camelot\"}"
        var checks=0
        assertFalse(owner.setChoice(owner.capture()!!,KeyNotation.Camelot){if(++checks==2)file.writeText(foreign);true})
        assertEquals(foreign,file.readText());assertEquals(KeyNotation.Musical,owner.state.value.choice)
        assertNull(owner.capture());assertEquals(KeyNotationError.Read,owner.state.value.error)
        val malformed=byteArrayOf(0xc3.toByte(),0x28)
        file.writeBytes(malformed);owner.load();assertNull(owner.capture());assertArrayEquals(malformed,file.readBytes())
        assertEquals(KeyNotation.Musical,owner.state.value.choice)
        assertTrue(file.parentFile!!.listFiles()!!.none {it.name.endsWith(".new")})
    }
    @Test fun dismissedOrRetiredAccountCannotMutateAtAdmissionOrFinalReplace()=withFile {file->
        val owner=KeyNotationPreferences(file);owner.load()
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore())
        session.accept(session.beginIntent(),SecretTokens("a","r","one"))
        val account=session.capture()!!;var mounted=true
        val valid={mounted&&session.current(account)}
        val captured=owner.capture()!!;mounted=false
        assertFalse(owner.setChoice(captured,KeyNotation.Musical,valid));assertFalse(file.exists())
        mounted=true;session.retire()
        session.accept(session.beginIntent(),SecretTokens("b","s","one"))
        assertFalse(owner.setChoice(captured,KeyNotation.Musical,valid));assertFalse(file.exists())
        var calls=0
        assertFalse(owner.setChoice(owner.capture()!!,KeyNotation.Musical){++calls==1})
        assertFalse(file.exists());assertEquals(KeyNotation.Camelot,owner.state.value.choice)
        assertTrue(file.parentFile!!.listFiles()!!.none {it.name.endsWith(".new")})
        owner.load();assertTrue(owner.setChoice(owner.capture()!!,KeyNotation.Musical){true})
        session.retire()
        val rebuilt=KeyNotationPreferences(file);rebuilt.load();assertEquals(KeyNotation.Musical,rebuilt.state.value.choice)
    }
}
