package com.soundq.android.playback

/** Command snapshot, not a queue owner. Controller is compared by identity. */
internal data class ReorderSnapshot<C:Any>(val controller:C,val revision:Long,val order:List<String>)
internal class QueueReorderCommands<C:Any>(private val read:()->ReorderSnapshot<C>?,private val move:(C,Int,Int)->Unit) {
    fun capture(authority:()->Boolean):QueueReorderRoute<C>? = read()?.let { QueueReorderRoute(it,authority,read,move) }
}
internal class QueueReorderRoute<C:Any>(private val captured:ReorderSnapshot<C>,private val authority:()->Boolean,
    private val read:()->ReorderSnapshot<C>?,private val move:(C,Int,Int)->Unit):AutoCloseable {
    private var active=true
    fun move(occurrence:String,order:List<String>,to:Int):Boolean {
        val current=read() ?: return false
        if(!active||!authority()||current.controller!==captured.controller||current.revision!=captured.revision||
            current.order!=captured.order||order!=captured.order||order.distinct().size!=order.size)return false
        val from=current.order.indexOf(occurrence)
        if(from<0||to !in current.order.indices||from==to)return false
        active=false
        move(current.controller,from,to);return true
    }
    override fun close(){active=false}
}
