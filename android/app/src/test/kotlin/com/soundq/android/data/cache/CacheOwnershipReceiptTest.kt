package com.soundq.android.data.cache

import com.soundq.android.data.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.attribute.BasicFileAttributes
import kotlinx.serialization.json.*

class CacheOwnershipReceiptTest {
    @Test fun forgedIndexCannotAdoptOrDeleteSameByteForeignUuidFile() {
        val dir=Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"cache-forged-index").toFile().canonicalFile
        try {
            val s=AccountSession(ApiEndpoint.parse("https://cache.example.test/api/v1"),object:SessionStore {
                override fun load(endpoint:ApiEndpoint):SecretTokens?=null
                override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){}
                override fun clear(){}
            });s.accept(s.beginIntent(),SecretTokens("a","r","A"));val scope=s.capture()!!
            val cache=TemporaryAudioCache(dir,s);val w=cache.begin(scope,TrackId(7),4)!!;w.append(byteArrayOf(1,2,3,4),0,4);assertTrue(w.finish())
            val original=dir.listFiles()!!.single {it.extension=="audio"}
            val foreign=dir.resolve("11111111-1111-4111-8111-111111111111.audio").apply {writeBytes(original.readBytes())}
            val key=Files.readAttributes(foreign.toPath(),BasicFileAttributes::class.java,NOFOLLOW_LINKS).fileKey().toString()
            val index=dir.resolve("temporary-audio.v1.json")
            val body=Json.parseToJsonElement(index.readText()).jsonObject
            val row=body.getValue("entries").jsonArray.single().jsonObject.toMutableMap().apply {put("name",JsonPrimitive(foreign.name));put("fileKey",JsonPrimitive(key))}
            index.writeText(JsonObject(body.toMutableMap().apply {put("entries",JsonArray(listOf(JsonObject(row))))}).toString())
            val rebuilt=TemporaryAudioCache(dir,s)
            assertNull("an index alone cannot authorize a foreign artifact",rebuilt.acquire(scope,TrackId(7)))
            rebuilt.clear();assertTrue(foreign.exists());assertArrayEquals(byteArrayOf(1,2,3,4),foreign.readBytes())
        } finally {dir.deleteRecursively()}
    }
}
