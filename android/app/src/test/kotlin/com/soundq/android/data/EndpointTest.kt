package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test

class EndpointTest {
    @Test fun refusesNormalizationBeforeAnyRequest() {
        val malformed = listOf("https://host.test/api/v1?secret=x", "https://u:p@host.test/api/v1", "https://host.test/a/../api/v1", "https://host.test/%2e/api/v1", "https://host.test/api//v1", "http://host.test/api/v1", " https://host.test/api/v1", "https://host.test/api/v1#x", "https://host.test/api/v1\\x")
        malformed.forEach { input ->
            val accepted = runCatching { ApiEndpoint.parse(input) }.isSuccess
            assertFalse("must refuse $input before normalization", accepted)
        }
        assertEquals("https://music.example.com/api/v1", ApiEndpoint.parse("https://music.example.com/api/v1").identity)
    }
    @Test fun secretsNeverHaveGeneratedToString() {
        assertFalse(SecretTokens("access-secret", "refresh-secret", "account").toString().contains("secret"))
    }
}
