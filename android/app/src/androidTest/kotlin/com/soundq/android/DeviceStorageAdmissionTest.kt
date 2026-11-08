package com.soundq.android

import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.data.offline.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Actual Android private-path admission, independent of UI and transfer networking. */
class DeviceStorageAdmissionTest {
    @Test fun ordinaryPrivateStorageCanClaimAnExplicitDownloadWithoutWeakeningCustody() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication).graph
        graph.session.accept(graph.session.beginIntent(),SecretTokens("synthetic-fixture-access","synthetic-fixture-refresh","fixture-account"))
        val scope=graph.session.capture()!!
        val rows=mutableListOf<String>();var path:File?=File(graph.directory,"device-downloads")
        while(path!=null) {val p=path;rows.add("${p.path}:symbolic=${Files.isSymbolicLink(p.toPath())}:canonical=${p.canonicalPath}");path=p.parentFile}
        Log.i("SoundQStorageProof",rows.joinToString(";"))
        graph.downloads.load(scope)
        Log.i("SoundQStorageProof","afterLoad=${graph.downloads.state.value}")
        assertFalse("ordinary private path must admit storage before HTTP",graph.downloads.state.value.rejected)
        val ticket=graph.downloads.claim(scope,Track(TrackId(1),"Fixture 1","Synthetic ensemble",durationMs=12000)){true}
        Log.i("SoundQStorageProof","claimed=${ticket!=null};state=${graph.downloads.state.value}")
        assertNotNull("ordinary storage must admit explicit download before transfer",ticket)
        graph.downloads.cancel(scope,graph.downloads.state.value.rows.single())
    }
}
