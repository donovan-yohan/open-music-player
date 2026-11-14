package com.soundq.android.playback.nativeengine

import java.io.Closeable

/** The descriptor portion of the existing source drain, including acquisition failures
 * before a typed source can return to the native owner. Failed closes remain retained.
 * Keys are physical catalog IDs for playback and captured routes for exact catalog proofs. */
internal object OriginalDescriptorCustody {
    private val retained=mutableSetOf<Ticket>()
    internal class Ticket internal constructor(val key:String,private val release:()->Unit):Closeable {
        private var closed=false
        private var failed:Throwable?=null
        @Synchronized override fun close() {
            failed?.let {throw java.io.IOException("Previous original descriptor close was not certified",it)}
            if(closed)return
            try {release()} catch(error:Throwable) {failed=error;throw error}
            closed=true
            synchronized(retained) {retained.remove(this)}
        }
    }
    fun own(key:String,release:()->Unit):Ticket = Ticket(key,release).also {synchronized(retained) {retained.add(it)}}
    fun drained(keys:Set<String>?=null):Boolean = synchronized(retained) {retained.none {keys==null || it.key in keys}}
}
