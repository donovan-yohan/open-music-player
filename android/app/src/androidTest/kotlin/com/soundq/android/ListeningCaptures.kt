package com.soundq.android

import android.graphics.Bitmap
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File

/** Full OS frames of synthetic fixtures, not component-only or reference renders. */
internal fun captureListeningStage(name: String) {
    require(name.matches(Regex("[a-zA-Z0-9-]+")))
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    instrumentation.waitForIdleSync()
    instrumentation.uiAutomation.waitForIdle(500, 3000)
    val label = InstrumentationRegistry.getArguments().getString("captureLabel") ?: "default"
    require(label.matches(Regex("[a-zA-Z0-9-]+")))
    val directory = File(instrumentation.targetContext.getExternalFilesDir(null), "listening-20261105/$label")
    check(directory.mkdirs() || directory.isDirectory)
    val image = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
    try {
        File(directory, "$name.png").outputStream().use {
            check(image.compress(Bitmap.CompressFormat.PNG, 100, it))
        }
    } finally { image.recycle() }
}
