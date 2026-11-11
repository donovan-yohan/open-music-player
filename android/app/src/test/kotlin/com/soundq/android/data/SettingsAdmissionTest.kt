package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class SettingsAdmissionTest {
    @Test fun retiredRouteCannotWriteEvenWhenQueuedBeforeDispatch() {
        val directory=Files.createTempDirectory("settings-admission").toFile()
        try {
            val file=directory.resolve("preferences")
            val owner=QueueSettingsRepository(FileQueuePreferencesStore(file));owner.load()
            val captured=owner.capture()!!
            var mounted=false
            // Invoke the actual production setter, including its dispatch-time predicate.
            val method=owner.javaClass.methods.firstOrNull {it.name=="setKeepQueued"&&it.parameterCount==3}
            val accepted=if(method==null)owner.setKeepQueued(captured,false) else method.invoke(owner,captured,false,{mounted}) as Boolean
            assertFalse("a retired route must not save an installation choice",accepted)
            assertFalse(file.exists());assertTrue(owner.state.value.keepQueued)
            mounted=true
        } finally {directory.deleteRecursively()}
    }
}
