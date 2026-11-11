package com.soundq.android.data

import com.soundq.android.data.catalog.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class CatalogContractTest {
    @Test fun actualMusicBrainzSearchUsesMbidNotLocalLibraryShape() {
        val parsed=runCatching {CatalogJson.search(Json.parseToJsonElement(search()).jsonObject,0)}.getOrNull()
        assertEquals("actual Go MusicBrainz search must publish the artist MBID",A,parsed?.rows?.singleOrNull()?.id?.value)
        assertEquals(1,parsed?.total)
    }
    @Test fun localAlbumSearchGrantsOnlyConcreteReleaseNavigationNotPlayback() {
        val page=runCatching {CatalogJson.releases(Json.parseToJsonElement(releases()).jsonObject,0)}.getOrNull()
        assertEquals(R,page?.rows?.firstOrNull()?.id?.value)
        assertNull(page?.rows?.lastOrNull()?.id)
    }
    companion object {
        fun releases()="""{"data":[{"id":8,"name":"Concrete album","mbReleaseId":"$R","trackCount":1},{"id":9,"name":"Local metadata only","trackCount":2}],"total":2,"limit":20,"offset":0}"""

        const val A="123e4567-e89b-12d3-a456-426614174001"
        const val G="123e4567-e89b-12d3-a456-426614174002"
        const val R="123e4567-e89b-12d3-a456-426614174003"
        const val T="123e4567-e89b-12d3-a456-426614174004"
        fun search()="""{"results":[{"mbid":"$A","name":"海 & artist","score":100}],"total":1,"limit":20,"offset":0}"""
        fun artist()="""{"id":"$A","name":"海 & artist","releases":[{"id":"$G","title":"A release group","date":"2020"}]}"""
        fun album()="""{"id":"$R","title":"Concrete album","artist":"海 & artist","artistId":"$A","trackCount":1,"tracks":[{"id":"$T","title":"Catalog recording","position":1,"duration":120000,"inLibrary":false,"downloadable":false}]}"""
    }
}
