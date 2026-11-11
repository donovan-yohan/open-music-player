package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test

class MixExchangeTest {
    @Test fun canonicalTransportForwardsRawDuplicateInputWithoutJsonNormalization() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val raw=" \n{\"name\":\"été\",\"name\":\"duplicate\"}\n "
            f.reply("{}",201)
            api.mixExchange(session.capture()!!,rawImport=raw){true}
            assertEquals(raw,f.server.takeRequest(2,java.util.concurrent.TimeUnit.SECONDS)!!.body!!.utf8())
        }
    }
    // Existing authorized transport, not a missing new feature symbol. The raw error must
    // retain only a declared safe code, never the server's message or supplied hashes.
    @Test fun canonicalImportTransportRetainsOnlyAllowlistedSourceRefusal() {
        HttpsFixture().use { f ->
            val session=AccountSession(f.endpoint,MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
            val api=SoundQApi(session,f.client)
            f.reply("""{"code":"MISSING_SOURCES","message":"private-secret https://secret.invalid","missingSourceHashes":["private-hash"]}""",422)
            val method=SoundQApi::class.java.declaredMethods.single {it.name=="authorized"}
            method.isAccessible=true
            val values=arrayOf<Any?>(session.capture()!!,"/mix-plans/import","POST",null,false,{true},201,null,null,false,emptyMap<String,String>(),false,false)
            val args=arrayOfNulls<Any?>(method.parameterCount)
            values.copyInto(args)
            val error=runCatching {method.invoke(api,*args)}.exceptionOrNull()!!.cause!!
            assertTrue("An admitted exchange refusal must retain its safe code: $error",error.toString().contains("MISSING_SOURCES"))
            for (secret in listOf("private-secret","secret.invalid","private-hash"))assertFalse(error.toString().contains(secret))
            assertEquals(1,f.server.requestCount)
        }
    }
}
