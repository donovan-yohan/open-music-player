package com.soundq.android.data.jam

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.net.URI

class JamGuestOriginTest {
    private val party="123e4567-e89b-42d3-a456-426614174000"
    private val dummy="A".repeat(43)
    private fun invite()=JamInvite.parse(buildJsonObject {put("joinToken",dummy);put("inviteExpiresAt","2030-01-01T00:00:00Z")})
    @Test fun explicitHttpsAndLocalDevelopmentOriginsKeepExactFragmentIdentity() {
        for(origin in listOf("https://guest.example.test","https://guest.example.test:8443/","http://localhost:8788","http://127.0.0.1:8788/","http://[::1]:8788")) {
            val link=invite().link(origin,party);val parsed=URI(link)
            assertEquals(origin.removeSuffix("/")+"/join",link.substringBefore('#'))
            assertEquals("jamId=$party&invite=$dummy",parsed.rawFragment);assertNull(parsed.rawQuery)
        }
    }
    @Test fun noPublicHttpCredentialsPathQueryOrFragmentIsAccepted() {
        for(origin in listOf("","guest.example.test","http://guest.example.test","http://127.0.0.1.evil.test:8788","https://name:password@guest.example.test","https://guest.example.test/page","https://guest.example.test?query=x","https://guest.example.test#fragment","http://localhost:0","http://localhost:65536")) {
            assertTrue("invalid guest origin accepted",runCatching {invite().link(origin,party)}.isFailure)
        }
    }
    @Test fun invalidLiteralPartyIdentifierIsNotNormalized() {
        assertTrue(runCatching {invite().link("https://"+"a".repeat(600)+".example.test",party)}.isFailure)
        assertTrue(runCatching {invite().link("https://guest.example.test",party.uppercase())}.isFailure)
        assertTrue(runCatching {invite().link("https://guest.example.test"," $party")}.isFailure)
        assertFalse(invite().toString().contains(dummy))
    }
}
