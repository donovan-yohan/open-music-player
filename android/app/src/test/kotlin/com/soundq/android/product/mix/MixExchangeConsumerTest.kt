package com.soundq.android.product.mix

import com.soundq.android.data.*
import com.soundq.android.data.mix.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

/** Real retained consumer + released owner + canonical synthetic HTTPS transport. */
class MixExchangeConsumerTest {
    private fun asset(name:String)=javaClass.getResource("/mix-exchange/$name")!!.readText()
    private fun setup(f:HttpsFixture):Pair<AccountSession,SoundQApi> {
        val session=AccountSession(f.endpoint,MemoryStore())
        session.accept(session.beginIntent(),SecretTokens("a","r","A"))
        return session to SoundQApi(session,f.client)
    }
    private fun saved()=MixJson.saved(Json.parseToJsonElement(asset("import-ack.json")).jsonObject)

    @Test fun routeReturnRetainsUnknownAttemptWithoutRepeatingPost() {HttpsFixture().use {f->
        val (session,api)=setup(f);val retained=MixExchangeRetained(api)
        val first=retained.open(session.capture()!!)!!;val old=first.capture()
        old.binding.edit(asset("import-input.json"));f.reply("{}",503);assertNull(old.binding.importMix())
        first.close();val returned=retained.open(session.capture()!!)!!;val fresh=returned.capture()
        assertFalse(first.current(old));assertEquals(ExchangePhase.Retired,old.binding.snapshot().phase)
        assertEquals(ExchangePhase.UnknownCreate,fresh.binding.snapshot().phase)
        assertEquals(asset("import-input.json"),fresh.binding.snapshot().input)
        assertNull(fresh.binding.importMix());assertEquals(1,f.server.requestCount)
        assertTrue(fresh.binding.snapshot().blocksOtherWrites)
        assertFalse(fresh.binding.startAnotherImport(false));assertTrue(fresh.binding.startAnotherImport(true))
        assertTrue(fresh.binding.snapshot().priorUnconfirmed)
    }}
    @Test fun verifiedReturnIsNotPermissionToPublishAfterSelectionSameVersionAba() {HttpsFixture().use {f->
        val (session,api)=setup(f);val route=MixExchangeRetained(api).open(session.capture()!!)!!
        val origin=route.capture();origin.binding.edit(asset("import-input.json"))
        f.reply(asset("import-ack.json"),201);f.reply(asset("import-readback.json"))
        val verified=origin.binding.importMix()!!
        // Main-thread continuation is held after actual verified IO, before screen publication.
        assertTrue(route.select(origin,saved()));val middle=route.capture()
        assertTrue(route.select(middle,saved()));assertFalse(route.current(origin))
        assertFalse(route.select(origin,verified));assertTrue(route.current(route.capture()))
    }}
    @Test fun sameSavedIdentitySelectionTransitionPermanentlyRetiresCopy() {HttpsFixture().use {f->
        val (session,api)=setup(f);val route=MixExchangeRetained(api).open(session.capture()!!)!!
        assertTrue(route.select(route.capture(),saved()));val old=route.capture()
        f.reply(asset("export.json"));assertTrue(old.binding.loadExport())
        var copied="";assertTrue(old.binding.copyExport {copied=it});assertEquals(asset("export.json"),copied)
        assertTrue(route.select(old,saved()));assertFalse(route.current(old))
        assertFalse(old.binding.copyExport {fail("Retired clipboard callback")})
        assertFalse(route.capture().binding.copyExport {fail("Replacement has no export")})
    }}
    @Test fun clipboardFailureRetainsExactExportForExplicitFreshCopy() {HttpsFixture().use {f->
        val (session,api)=setup(f);val route=MixExchangeRetained(api).open(session.capture()!!)!!
        route.select(route.capture(),saved());val c=route.capture();f.reply(asset("export.json"));assertTrue(c.binding.loadExport())
        assertFalse(c.binding.copyExport {throw IllegalStateException("Platform clipboard unavailable")})
        assertEquals(asset("export.json"),c.binding.snapshot().exportText)
        var copied="";assertTrue(c.binding.copyExport {copied=it});assertEquals(asset("export.json"),copied)
        assertEquals(1,f.server.requestCount)
    }}
    @Test fun accountGenerationRetirementClearsPayloadAndCannotReviveOldRoute() {HttpsFixture().use {f->
        val (session,api)=setup(f);val retained=MixExchangeRetained(api)
        val route=retained.open(session.capture()!!)!!;val old=route.capture();old.binding.edit("private original")
        session.accept(session.beginIntent(),SecretTokens("a2","r2","A"));retained.retireObsolete()
        assertEquals("",old.binding.snapshot().input);assertFalse(route.current(old))
        val fresh=retained.open(session.capture()!!)!!;assertEquals("",fresh.capture().binding.snapshot().input)
        retained.retire();assertFalse(fresh.current(fresh.capture()));assertFalse(old.binding.edit("revive"))
        assertEquals(0,f.server.requestCount)
    }}
    @Test fun routeExitDuringPostRetainsUncertaintyAndRefusesLatePublication() {HttpsFixture().use {f->
        val (session,api)=setup(f);val retained=MixExchangeRetained(api);val route=retained.open(session.capture()!!)!!
        val origin=route.capture();origin.binding.edit(asset("import-input.json"))
        val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
        f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
            entered.countDown();check(release.await(5,TimeUnit.SECONDS));return mockwebserver3.MockResponse.Builder().code(201).body(asset("import-ack.json")).build()
        }}
        try {
            val work=pool.submit<SavedMix?> {origin.binding.importMix()};assertTrue(entered.await(3,TimeUnit.SECONDS))
            route.close();val fresh=retained.open(session.capture()!!)!!
            assertEquals(ExchangePhase.UnknownCreate,fresh.capture().binding.snapshot().phase)
            release.countDown();assertNull(work.get(4,TimeUnit.SECONDS));assertFalse(route.current(origin))
            assertEquals(1,f.server.requestCount);assertNull(fresh.capture().binding.importMix())
        }finally {release.countDown();pool.shutdownNow()}
    }}
}
