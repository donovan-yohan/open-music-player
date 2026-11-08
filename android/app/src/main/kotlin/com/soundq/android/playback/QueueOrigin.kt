package com.soundq.android.playback

/** Service metadata, durable observations and timeline projection share one typed origin. */
enum class QueueOrigin { Context, Manual, Continuation;
    companion object {
        fun read(value:String?,manual:Boolean):QueueOrigin=if(value==null) {if(manual)Manual else Context} else entries.firstOrNull {it.name==value} ?: Context
        fun saved(value:String?,manual:Boolean):QueueOrigin {
            if(value==null)return if(manual)Manual else Context
            return entries.single {it.name==value}.also {require((it==Manual)==manual)}
        }
    }
}
