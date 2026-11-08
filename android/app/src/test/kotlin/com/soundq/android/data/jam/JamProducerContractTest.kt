package com.soundq.android.data.jam

import com.soundq.android.data.SafeFailure
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Actual Go HTTP producer bytes; provider/storage and receipt are synthetic. */
class JamProducerContractTest {
    private fun producer(name:String):JsonObject = javaClass.getResourceAsStream("/jam-producer/$name.json")!!.bufferedReader().use {Json.parseToJsonElement(it.readText()).jsonObject}
    private fun parse(value:JsonObject,host:Boolean=true)=JamSnapshot.parse(value,host,value.getValue("jamId").jsonPrimitive.content)

    @Test fun currentGoProducerPendingImportingReadyAndReceiptDecodeWithoutCallingAcquisitionQueued() {
        for ((name,status) in listOf("host-pending" to "pending","host-importing" to "importing","host-ready" to "ready","host-receipt-reconciled" to "queued")) {
            val snapshot=parse(producer(name))
            assertEquals(status,snapshot.requests.first().status)
            if(status in setOf("pending","importing"))assertNull(snapshot.requests.first().trackId)
            if(status=="ready")assertEquals(2L,snapshot.requests.first().trackId!!.value)
            assertEquals(status=="queued",snapshot.requests.first().receipt!=null)
        }
    }
    @Test fun currentGuestProjectionAcceptsSafeSourceButNeverPrivateMappings() {
        val wire=producer("guest-ready")
        assertTrue(parse(wire,false).requests.all {it.trackId==null&&it.receipt==null})
        val polluted=JsonObject(wire+mapOf("ownerUserId" to JsonPrimitive("87b2abbb-f74b-42bc-9fc7-d321d5c04d88")))
        assertThrows(SafeFailure::class.java){parse(polluted,false)}
    }
    @Test fun mismatchedHostAndPublicSourceCannotPassIdentityValidation() {
        val wire=producer("host-ready")
        val rows=wire.getValue("hostRequests").jsonArray.toMutableList()
        val row=rows.first().jsonObject
        val source=row.getValue("source").jsonObject
        rows[0]=JsonObject(row+mapOf("source" to JsonObject(source+mapOf("sourceId" to JsonPrimitive("different-recording")))))
        assertThrows(SafeFailure::class.java){parse(JsonObject(wire+mapOf("hostRequests" to JsonArray(rows))))}
    }
    @Test fun actualReadinessRetainsHostAuthorityExactSourceMembersAndApprovalOrder() {
        val snapshot=parse(producer("host-ready"))
        assertTrue(snapshot.outsideDiscovery)
        assertEquals("87b2abbb-f74b-42bc-9fc7-d321d5c04d88",snapshot.authority!!.ownerId)
        assertEquals(2,snapshot.members.size)
        val first=snapshot.requests.first()
        assertEquals("https://www.youtube.com/watch?v=jam-exact-live",first.selectedSource!!.sourceUrl)
        assertEquals(1L,first.approvalOrder);assertTrue(first.canAdmit)
        assertEquals(2L,snapshot.requests.last().approvalOrder);assertFalse(snapshot.requests.last().canAdmit)
        assertEquals("synthetic-host-incarnation-1",first.hostSessionId)
        assertEquals(64,first.admissionKey!!.length)
    }
    @Test fun offeredOnlyLegacyShapeRemainsReadableWithoutFabricatingModernAuthority() {
        val wire=producer("host-ready")
        val public=JsonObject(wire.getValue("requests").jsonArray.last().jsonObject.filterKeys {it!="source"}+mapOf("status" to JsonPrimitive("pending")))
        val old=JsonObject(wire.filterKeys {it !in setOf("ownerUserId","ownerAuthGeneration","hostDeviceId","leaseId","members","allowOutsideDiscovery","hostRequests","requests")}+mapOf("requests" to JsonArray(listOf(public)),"hostRequests" to JsonArray(listOf(JsonObject(public+mapOf("trackId" to JsonPrimitive(1)))))))
        val snapshot=parse(old)
        assertNull(snapshot.authority);assertFalse(snapshot.outsideDiscovery);assertTrue(snapshot.members.isEmpty())
        assertEquals(1L,snapshot.requests.single().trackId!!.value)
    }
    @Test fun actualSparseGoPrivateCaptureMayOmitUnknownArtistAndDurationWithoutBecomingPlayable() {
        val wire=producer("host-sparse-pending")
        val selected=wire.getValue("hostRequests").jsonArray.single().jsonObject.getValue("selectedSource").jsonObject
        assertFalse(selected.containsKey("artist"));assertFalse(selected.containsKey("durationMs"))
        val request=parse(wire).requests.single()
        assertEquals("Sparse recording (synthetic)",request.source!!.title)
        assertEquals("",request.source.artist);assertEquals(0L,request.source.durationMs)
        assertEquals("https://www.youtube.com/watch?v=jam-sparse",request.selectedSource!!.sourceUrl)
        assertNull(request.trackId);assertFalse(request.canAdmit);assertEquals("pending",request.status)
    }
}
