package com.soundq.android

import android.app.Application
import android.content.Context
import androidx.test.runner.AndroidJUnitRunner

/** Direct JNI/codec tests only. No SoundQ graph, controller, service or second engine.
 * Assemble with -POMP_TEST_RUNNER=com.soundq.android.DirectCodecFixtureRunner.
 * Service integration remains on CallbackFrontendFixtureRunner.
 */
class DirectCodecFixtureRunner:AndroidJUnitRunner() {
    override fun newApplication(cl:ClassLoader,className:String,context:Context):Application =
        super.newApplication(cl,Application::class.java.name,context)
}
