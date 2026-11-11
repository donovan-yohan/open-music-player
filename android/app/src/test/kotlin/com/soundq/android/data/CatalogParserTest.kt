package com.soundq.android.data

import com.soundq.android.data.catalog.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class CatalogParserTest {
    private fun objectOf(s:String)=Json.parseToJsonElement(s).jsonObject
    private fun reject(block:()->Any) {assertEquals(SafeFailure.Reason.InvalidResponse,(runCatching(block).exceptionOrNull() as? SafeFailure)?.reason)}
    @Test fun artistStrictIdentityOptionalCollectionsAndReleaseGroupNamespace() {
        val expected=ArtistMbid(CatalogContractTest.A)
        assertTrue(CatalogJson.artist(objectOf("""{"id":"${expected.value}","name":"Valid"}"""),expected).releases.isEmpty())
        for(body in listOf(CatalogContractTest.artist().replace("海 & artist",""),CatalogContractTest.artist().replace("\"name\":\"海 & artist\"","\"name\":2"),CatalogContractTest.artist().replace("\"releases\":[", "\"releases\":null,\"unused\":["),CatalogContractTest.artist().replace(CatalogContractTest.A,CatalogContractTest.R))) reject {CatalogJson.artist(objectOf(body),expected)}
        for(id in listOf("7",CatalogContractTest.A.uppercase(),"../${CatalogContractTest.A}"," ${CatalogContractTest.A}"))assertTrue(runCatching {ArtistMbid(id)}.isFailure)
    }
    @Test fun albumRequiresRecordingNamespaceAndBooleanScalarButNeverGrantsLibraryAuthority() {
        val id=ReleaseMbid(CatalogContractTest.R)
        val album=CatalogJson.album(objectOf(CatalogContractTest.album()),id)
        assertEquals(120000L,album.tracks.single().durationMs)
        for(body in listOf(CatalogContractTest.album().replace("\"id\":\"${CatalogContractTest.T}\"","\"id\":7"),CatalogContractTest.album().replace("\"duration\":120000","\"duration\":\"120000\""),CatalogContractTest.album().replace("\"position\":1","\"position\":1.5"),CatalogContractTest.album().replace("\"inLibrary\":false","\"inLibrary\":null"),CatalogContractTest.album().replace("\"downloadable\":false","\"downloadable\":\"false\"")))reject {CatalogJson.album(objectOf(body),id)}
        val flagged=CatalogJson.album(objectOf(CatalogContractTest.album().replace("\"inLibrary\":false","\"inLibrary\":true")),id)
        assertEquals(CatalogContractTest.T,flagged.tracks.single().id.value) // Still a RecordingMbid; not a TrackId.
        val noCount=CatalogJson.album(objectOf("""{"id":"${id.value}","title":"Unknown tracks"}"""),id)
        assertNull(noCount.trackCount);assertTrue(noCount.tracks.isEmpty())
        val repeated=objectOf(CatalogContractTest.album()).toMutableMap();val track=repeated.getValue("tracks").jsonArray.single();repeated["tracks"]=JsonArray(listOf(track,track));repeated["trackCount"]=JsonPrimitive(2)
        assertEquals(2,CatalogJson.album(JsonObject(repeated),id).tracks.size)
    }
    @Test fun searchRejectsLocalEnvelopeCoercionAndBadPagination() {
        for(body in listOf(CatalogContractTest.search().replace("\"results\"","\"data\""),CatalogContractTest.search().replace("\"total\":1","\"total\":\"1\""),CatalogContractTest.search().replace("\"limit\":20","\"limit\":4294967316"),CatalogContractTest.search().replace("\"offset\":0","\"offset\":20"),CatalogContractTest.search().replace("\"score\":100","\"score\":101")))reject {CatalogJson.search(objectOf(body),0)}
    }
}
