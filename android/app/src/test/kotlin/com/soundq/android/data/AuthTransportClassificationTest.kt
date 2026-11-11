package com.soundq.android.data

import mockwebserver3.MockResponse
import mockwebserver3.SocketEffect
import okhttp3.Dns
import org.junit.Assert.*
import org.junit.Test
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Uses only pre-existing APIs: replay identical bytes on original SoundQApi.kt for causal DNS RED. */
class AuthTransportClassificationTest {
    @Test fun resolverUnknownHostBeforeCredentialPostIsNetworkWithNoHttpRequestOrRetry() {
        for(register in listOf(false,true)) HttpsFixture().use {f ->
            val lookups=AtomicInteger();val client=f.client.newBuilder().dns(object:Dns {
                override fun lookup(hostname:String):List<InetAddress> {lookups.incrementAndGet();throw UnknownHostException("synthetic unreachable host")}
            }).build()
            try {
                val session=AccountSession(f.endpoint,MemoryStore());val api=SoundQApi(session,client)
                assertFalse(api.authenticate("synthetic@example.test","test-only-password",if(register)"Synthetic" else null))
                val state=session.state.value as AuthState.SignedOut
                assertEquals(SafeFailure.Reason.Network,state.error);assertFalse(state.uncertain)
                assertEquals(1,lookups.get());assertEquals(0,f.server.requestCount);assertNull(session.capture())
            } finally {client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()}
        }
    }
    @Test fun resolverUnknownHostDuringSavedRefreshKeepsSavedBytesAndNetworkSpecificReason() {
        HttpsFixture().use {f ->
            val lookups=AtomicInteger();val client=f.client.newBuilder().dns(object:Dns {
                override fun lookup(hostname:String):List<InetAddress> {lookups.incrementAndGet();throw UnknownHostException("synthetic unreachable host")}
            }).build()
            try {
                val store=MemoryStore().apply {tokens=SecretTokens("old","old-r","A")};val original=store.tokens
                val session=AccountSession(f.endpoint,store)
                assertFalse(SoundQApi(session,client).restore())
                assertEquals(SafeFailure.Reason.Network,(session.state.value as AuthState.SignedOut).error)
                assertSame(original,store.tokens);assertEquals(0,store.writes);assertEquals(1,lookups.get());assertEquals(0,f.server.requestCount)
            } finally {client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()}
        }
    }
    @Test fun disconnectAfterServerReceivesCredentialPostRemainsUncertainWithNoRetry() {
        HttpsFixture().use {f ->
            f.server.enqueue(MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build())
            val store=MemoryStore();val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            assertFalse(api.authenticate("synthetic@example.test","test-only-password"))
            val received=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("POST",received.method);assertEquals("/api/v1/auth/login",received.url.encodedPath)
            val state=session.state.value as AuthState.SignedOut
            assertEquals(SafeFailure.Reason.Uncertain,state.error);assertTrue(state.uncertain)
            assertEquals(1,f.server.requestCount);assertEquals(0,store.writes);assertNull(session.capture())
        }
    }
}
