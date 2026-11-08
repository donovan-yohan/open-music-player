package com.soundq.android.data.preferences

import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class AppearancePreferencesTest {
    @Test fun missingChoiceDefaultsToSystem() {
        assertEquals("System", ListeningPreferences().appearance.name)
    }
    @Test fun foreignOwnerCaptureCannotWriteEvenAtSameRevision() {
        val dir=Files.createTempDirectory("appearance-capture").toFile()
        try {
            val a=AppearancePreferences(dir.resolve("a"));a.load()
            val file=dir.resolve("b");val b=AppearancePreferences(file);b.load()
            assertFalse(b.setChoice(a.capture()!!,Appearance.Dark){true})
            assertFalse(file.exists());assertEquals(Appearance.System,b.state.value.choice)
        } finally {dir.deleteRecursively()}
    }
    @Test fun rejectedBytesAndReadFailuresPreserveAcceptedChoice() {
        val dir=Files.createTempDirectory("appearance-rejected").toFile()
        try {
            val file=dir.resolve("appearance");val owner=AppearancePreferences(file);owner.load()
            assertFalse(file.exists());assertEquals(Appearance.System,owner.state.value.choice)
            assertTrue(owner.setChoice(owner.capture()!!,Appearance.Dark){true})
            for(raw in listOf("broken","{\"version\":2,\"appearance\":\"light\"}","{\"version\":1,\"appearance\":\"future\"}","{\"version\":1,\"appearance\":2}"," ".repeat(4097))) {
                file.writeText(raw);owner.load()
                assertEquals(Appearance.Dark,owner.state.value.choice)
                assertEquals(AppearanceError.Read,owner.state.value.error);assertNull(owner.capture())
                val fresh=AppearancePreferences(file);fresh.load()
                assertEquals(Appearance.System,fresh.state.value.choice);assertNull(fresh.capture())
                assertEquals(raw,file.readText())
            }
            file.delete();file.mkdir();owner.load()
            assertEquals(Appearance.Dark,owner.state.value.choice);assertNull(owner.capture());assertTrue(file.isDirectory)
            file.delete();file.writeText("{\"version\":1,\"appearance\":\"light\"}");owner.load()
            assertEquals(Appearance.Light,owner.state.value.choice);assertNotNull(owner.capture())
        } finally {dir.deleteRecursively()}
    }
    @Test fun failedWriteHasExplicitRetryWithoutPublishingOrReplay() {
        val dir=Files.createTempDirectory("appearance-write").toFile()
        try {
            val parent=dir.resolve("parent");parent.writeText("blocked")
            val file=parent.resolve("appearance");val owner=AppearancePreferences(file);owner.load()
            val capture=owner.capture()!!
            assertFalse(owner.setChoice(capture,Appearance.Light){true})
            assertEquals(Appearance.System,owner.state.value.choice);assertEquals(AppearanceError.Write,owner.state.value.error)
            parent.delete();parent.mkdir()
            assertFalse(file.exists());assertFalse(owner.setChoice(capture,Appearance.Dark){true})
            assertTrue(owner.setChoice(owner.capture()!!,Appearance.Light){true})
            assertEquals(Appearance.Light,owner.state.value.choice)
        } finally {dir.deleteRecursively()}
    }
    @Test fun staleDismissedAndReplacedBytesRefuseWithoutMutation() {
        val dir=Files.createTempDirectory("appearance-stale").toFile()
        try {
            val file=dir.resolve("appearance");val owner=AppearancePreferences(file);owner.load()
            val old=owner.capture()!!
            assertFalse(owner.setChoice(old,Appearance.Light){false});assertFalse(file.exists())
            assertTrue(owner.setChoice(old,Appearance.Dark){true});val accepted=file.readBytes()
            assertFalse(owner.setChoice(old,Appearance.Light){true});assertArrayEquals(accepted,file.readBytes())
            val next=owner.capture()!!;var checks=0
            assertFalse(owner.setChoice(next,Appearance.Light){++checks==1})
            assertArrayEquals(accepted,file.readBytes());assertEquals(Appearance.Dark,owner.state.value.choice)
            val foreign="{\"version\":99,\"appearance\":\"light\"}";file.writeText(foreign)
            assertFalse(owner.setChoice(owner.capture()!!,Appearance.Light){true});assertEquals(foreign,file.readText())
            assertTrue(dir.listFiles()!!.none {it.name.endsWith(".new")})
        } finally {dir.deleteRecursively()}
    }
    @Test fun acceptedChoiceRoundTripsActualBytes() {
        val dir=Files.createTempDirectory("appearance-roundtrip").toFile()
        try {
            val file=dir.resolve("appearance.v1.json")
            val owner=AppearancePreferences(file);owner.load()
            for(choice in Appearance.entries) {
                assertTrue(owner.setChoice(owner.capture()!!,choice){true})
                assertEquals("{\"version\":1,\"appearance\":\"${choice.wire}\"}",file.readText())
                val rebuilt=AppearancePreferences(file);rebuilt.load()
                assertEquals(choice,rebuilt.state.value.choice)
                assertTrue(rebuilt.state.value.ready);assertNull(rebuilt.state.value.error)
            }
        } finally {dir.deleteRecursively()}
    }
}
