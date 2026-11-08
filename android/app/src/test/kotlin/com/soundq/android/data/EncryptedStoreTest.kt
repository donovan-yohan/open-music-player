package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import javax.crypto.KeyGenerator

class EncryptedStoreTest {
    @Test fun encryptedAtomicRoundTripAndRejectedBytesPreserved() {
        val dir=Files.createTempDirectory("soundq-store").toFile()
        try {
            val file=dir.resolve("session"); val key=KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
            val store=EncryptedSessionStore(file) {key}; val endpoint=ApiEndpoint.parse("https://fixture.test/api/v1")
            store.save(endpoint,SecretTokens("access-secret","refresh-secret","fixture"))
            assertFalse(file.readBytes().toString(Charsets.ISO_8859_1).contains("secret"))
            assertEquals("fixture",store.load(endpoint)?.accountId)
            val original=file.readBytes()
            assertTrue(runCatching {store.load(ApiEndpoint.parse("https://other.test/api/v1"))}.isFailure)
            assertArrayEquals(original,file.readBytes())
            file.writeBytes(original.apply { this[lastIndex]=(this[lastIndex].toInt() xor 1).toByte() })
            val rejected=file.readBytes()
            assertTrue(runCatching {store.load(endpoint)}.isFailure)
            assertArrayEquals(rejected,file.readBytes())
            file.writeBytes(original.copyOf().apply {this[3]=99})
            val future=file.readBytes()
            assertTrue(runCatching {store.load(endpoint)}.isFailure);assertArrayEquals(future,file.readBytes())
            store.clear(); assertNull(store.load(endpoint))
        } finally {dir.deleteRecursively()}
    }
}
