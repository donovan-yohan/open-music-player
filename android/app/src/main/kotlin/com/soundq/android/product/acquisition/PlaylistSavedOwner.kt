package com.soundq.android.product.acquisition

/** Durable saved-state namespace, not a live AccountScope or dispatch capability. */
internal data class PlaylistSavedOwner(val endpoint:String,val account:String) {
    // Length framing keeps arbitrary endpoint/account strings unambiguous. Bump on schema changes.
    val providerKey:String get()="playlist-import:1:${endpoint.length}:$endpoint:${account.length}:$account"
    fun saveJob(job:String):List<String> {
        require(validJob(job))
        return listOf("1",endpoint,account,job)
    }
    /** Check the payload itself, not rememberSaveable's inputs or the process-local epoch. */
    fun restoreJob(payload:List<*>):String? {
        if(payload.size!=4||payload[0]!="1"||payload[1]!=endpoint||payload[2]!=account)return null
        return (payload[3] as? String)?.takeIf(::validJob)
    }
    private fun validJob(value:String)=runCatching {val id=java.util.UUID.fromString(value);id!=java.util.UUID(0,0)&&id.toString()==value}.getOrDefault(false)
}
