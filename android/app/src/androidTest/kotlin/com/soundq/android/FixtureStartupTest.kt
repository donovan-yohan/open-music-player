package com.soundq.android

import android.os.Looper
import androidx.test.platform.app.InstrumentationRegistry
import okhttp3.Request
import org.junit.Assert.*
import org.junit.Test

/** Android startup regression, not a host scheduling surrogate. */
class FixtureStartupTest {
    @Test fun fixtureGraphIsReadyBeforeTestsAndNetworkingStayedOffMain() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=instrumentation.targetContext.applicationContext as FixtureApplication
        instrumentation.runOnMainSync {
            assertSame(Looper.getMainLooper(),Looper.myLooper())
            assertTrue(app.graphCreatedOnMain)
            assertEquals(ProductTransportFixture.endpoint.identity,app.graph.endpoint.identity)
            assertTrue(ProductTransportFixture.networkingStayedOffMain)
            assertFalse(app.bootstrapThread.isAlive)
            assertEquals("https",app.graph.endpoint.identity.substringBefore(":"))
        }
        assertNotSame(Looper.getMainLooper(),Looper.myLooper())
        val requestsBefore=ProductTransportFixture.requests.size
        app.fixtureClient.newCall(Request.Builder().url(ProductTransportFixture.origin.resolve("/api/v1/library")!!).build()).execute().use {
            assertEquals(401,it.code)
        }
        assertTrue(ProductTransportFixture.requests.drop(requestsBefore).any {it=="GET /api/v1/library"})
    }
}
