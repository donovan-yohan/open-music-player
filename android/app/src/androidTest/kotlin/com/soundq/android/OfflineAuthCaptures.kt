package com.soundq.android

import android.graphics.Bitmap
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File

/** OS screenshots of synthetic fixture data only. Call after Compose has settled. */
internal fun captureOfflineAuthStage(name:String) {
    val instrumentation=InstrumentationRegistry.getInstrumentation()
    instrumentation.waitForIdleSync()
    instrumentation.uiAutomation.waitForIdle(500,3000)
    val directory=File(instrumentation.targetContext.getExternalFilesDir(null),"offline-auth-repair").also {check(it.mkdirs()||it.isDirectory)}
    val bitmap=checkNotNull(instrumentation.uiAutomation.takeScreenshot())
    try {File(directory,"$name.png").outputStream().use {check(bitmap.compress(Bitmap.CompressFormat.PNG,100,it))}}
    finally {bitmap.recycle()}
}
