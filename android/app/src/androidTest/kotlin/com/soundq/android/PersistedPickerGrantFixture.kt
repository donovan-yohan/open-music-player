package com.soundq.android

import android.content.Intent
import android.os.Environment
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

/** Upgrade-journey setup, run by the runner before the upgrade case of [LocalAudioAccessJourneyTest]: the shell hands
 * this package a persistable read grant, as an older build's file picker did, and the package takes it. No activity
 * rule: the shell's own launch owns the grant until it is persisted. */
class PersistedPickerGrantFixture {
    @Test fun olderBuildHoldsAPersistedPickerGrant() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        assertFalse("Runner must deny all files access so the grant is needed",Environment.isExternalStorageManager())
        val uri=android.net.Uri.parse(checkNotNull(InstrumentationRegistry.getArguments().getString("grantUri")))
        val resolver=instrumentation.targetContext.contentResolver
        val deadline=System.currentTimeMillis()+90_000
        while(System.currentTimeMillis()<deadline&&runCatching {resolver.takePersistableUriPermission(uri,Intent.FLAG_GRANT_READ_URI_PERMISSION)}.isFailure)Thread.sleep(200)
        assertTrue("The shell grant never arrived",resolver.persistedUriPermissions.any {it.uri==uri&&it.isReadPermission})
    }
}
