package com.soundq.android.playback.system

import com.soundq.android.data.*
import org.junit.Assert.*
import org.junit.Test

class SystemMediaCatalogTest {
    private class Store:SessionStore {var tokens:SecretTokens?=SecretTokens("a","r","A");override fun load(endpoint:ApiEndpoint)=tokens;override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){this.tokens=tokens};override fun clear(){tokens=null}}
    @Test fun pagingStableIdsDeviceOnlyAndRetirementAreEnforced() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store())
        session.accept(session.beginIntent(),SecretTokens("a","r","A"));val scope=session.capture()!!
        val rows=(1L..63L).map {Track(TrackId(it),"Track $it")};val offsets=mutableListOf<Int>()
        val catalog=SystemMediaCatalog(session,{_,_,offset -> offsets+=offset;LibraryPage(rows.drop(offset).take(20),63,20,offset)},{listOf(rows[6])})
        val page=catalog.page(scope,false,"",1,25)
        assertEquals((26L..50L).map {"library:$it"},page.tracks.map {it.mediaId});assertEquals(63,page.total)
        assertEquals(listOf(25,45),offsets)
        assertEquals("library:26",catalog.item(scope,"library:26")!!.mediaId)
        assertNull(catalog.item(scope,"library:1")) // only actually admitted browse entries
        assertEquals("device:7",catalog.page(scope,true,"Track 7",0,20).tracks.single().mediaId)
        assertTrue(catalog.item(scope,"device:7")!!.localOnly)
        for(id in listOf("library:0","library:-1","library:01","7","https://evil.invalid","device:999"))assertNull(catalog.item(scope,id))
        for(pair in listOf(-1 to 20,0 to 101,Int.MAX_VALUE to 100))try {catalog.page(scope,false,"",pair.first,pair.second);fail("unbounded page")}catch(_:IllegalArgumentException){}
        session.revoke()
        try {catalog.page(scope,false,"",0,20);fail("retired browse")}catch(_:SafeFailure){}
        assertNull(catalog.item(scope,"library:26"))
        val localSession=AccountSession(session.endpoint,Store());assertTrue(localSession.useDeviceDownloads());val device=localSession.capture()!!
        val localCatalog=SystemMediaCatalog(localSession,{_,_,_ -> error("device scope must not fetch")},{listOf(rows[6])})
        assertEquals(listOf("device:7"),localCatalog.page(device,false,"",0,20).tracks.map {it.mediaId})
        assertNull(localCatalog.item(device,"library:26"))
    }
    @Test fun heldRemoteReplyCannotPublishIntoReplacementAccount() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store());session.accept(session.beginIntent(),SecretTokens("a","r","A"));val scope=session.capture()!!
        val catalog=SystemMediaCatalog(session,{_,_,offset -> session.accept(session.beginIntent(),SecretTokens("b","br","B"));LibraryPage(listOf(Track(TrackId(1),"A private")),1,20,offset)},{emptyList()})
        try {catalog.page(scope,false,"",0,20);fail("stale publication")}catch(_:SafeFailure){}
        assertNull(catalog.item(session.capture()!!,"library:1"))
    }
}
