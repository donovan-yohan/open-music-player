package com.soundq.android

/** Synthetic opt-in recent envelope; not a replacement for canonical event aggregation tests. */
internal fun recentFixtureBody(body:String,offset:Int=0,hasMore:Boolean=false,revision:String="a".repeat(64)):String =
    org.json.JSONObject(body).put("limit",20).put("offset",offset).put("revision",revision).put("hasMore",hasMore).toString()

// A finite synthetic corpus for ordinary startup consumers, not Go wire evidence.
internal val ordinaryRecentRevision="b".repeat(64)
internal fun ordinaryRecentFixtureBody(offset:Int):String {
    require(offset>=0)
    val corpus=(1..23).map {id->
        """{"id":$id,"title":"Recent fixture $id","artist":"Synthetic ensemble","durationMs":12000,"inLibrary":${id!=23}}"""
    }
    val rows=corpus.drop(offset).take(20)
    return """{"tracks":[${rows.joinToString(",")}],"limit":20,"offset":$offset,"revision":"$ordinaryRecentRevision","hasMore":${offset+rows.size<corpus.size}}"""
}
