package com.soundq.android.data.preferences
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test
class SwipeQueuePreferencesTest {
 @Test fun persistedModesRejectStaleForeignCorruptAndFailedWrites() {
  val dir=Files.createTempDirectory("swipe-preference").toFile()
  try {
   val file=dir.resolve("swipe");val owner=SwipeQueuePreferences(file);owner.load()
   assertEquals(SwipeQueue.AddToQueue,owner.state.value.mode)
   for(mode in SwipeQueue.entries) {
    val capture=owner.capture()!!
    assertFalse(owner.setMode(capture,mode){false})
    assertTrue(owner.setMode(capture,mode){true})
    val bytes=file.readBytes()
    assertFalse(owner.setMode(capture,mode){true});assertArrayEquals(bytes,file.readBytes())
    val restored=SwipeQueuePreferences(file);restored.load();assertEquals(mode,restored.state.value.mode)
    assertFalse(restored.setMode(owner.capture()!!,mode){true})
   }
   val old=owner.capture()!!;file.writeText("corrupt")
   assertFalse(owner.setMode(old,SwipeQueue.AddToQueue){true});assertEquals("corrupt",file.readText())
   owner.load();assertNull(owner.capture());assertEquals(SwipeQueue.PlayNext,owner.state.value.mode)
   file.delete();file.mkdir();owner.load();assertNull(owner.capture());assertTrue(file.isDirectory)
   val blocked=dir.resolve("blocked");blocked.writeText("x")
   val fail=SwipeQueuePreferences(blocked.resolve("swipe"));fail.load()
   assertFalse(fail.setMode(fail.capture()!!,SwipeQueue.PlayNext){true})
   assertEquals(SwipeQueue.AddToQueue,fail.state.value.mode)
  }finally {dir.deleteRecursively()}
 }
}
