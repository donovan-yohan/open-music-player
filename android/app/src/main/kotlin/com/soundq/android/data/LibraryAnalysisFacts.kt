package com.soundq.android.data

import kotlinx.serialization.json.*

/** Optional compact Library facts, not timing/decoder or global Track authority. */
internal fun libraryAnalysisFacts(row:JsonObject):LibraryAnalysisFacts? {
    val summary=row["analysis_summary"] as? JsonObject
    val status=(row["analysis_status"] as? JsonPrimitive)?.takeIf {it.isString}?.content?.takeIf {it in setOf("pending","analyzing","analyzed","failed","stale","unsupported")}
    fun fact(name:String):JsonPrimitive? = (summary?.get(name) as? JsonObject)?.get("value") as? JsonPrimitive
    fun text(name:String)=fact(name)?.takeIf {it.isString}?.content?.trim()?.takeIf {it.isNotEmpty()&&it.length<=100}
    val bpm=fact("bpm")?.takeUnless {it.isString}?.doubleOrNull?.takeIf {it.isFinite()&&it>0}
    val key=text("key")
    val camelot=text("camelot")?.uppercase(java.util.Locale.ROOT)?.takeIf {Regex("(?:[1-9]|1[0-2])[AB]").matches(it)}
    return if(status==null&&bpm==null&&key==null&&camelot==null)null else LibraryAnalysisFacts(status,bpm,key,camelot)
}
