package com.soundq.android.product

import com.soundq.android.data.LibraryState
import java.util.concurrent.atomic.AtomicBoolean

/** One mounted observer visit. Pagination identity changes only on an accepted page read. */
internal class LibraryPaginationGate {
    private val alive=AtomicBoolean(true)
    private var requested:Pair<Long,Int>?=null
    fun current():Boolean=alive.get()
    fun close(){alive.set(false)}
    fun claim(state:LibraryState,lastVisible:Int,totalItems:Int,prefetchItems:Int):Boolean {
        val identity=state.pageRevision to state.nextOffset
        val ready=current()&&!state.loading&&state.error==null&&!state.endReached&&state.total!=null&&
            state.nextOffset<state.total&&state.rows.isNotEmpty()&&totalItems==state.rows.size&&
            lastVisible in 0 until totalItems&&lastVisible>=totalItems-1-prefetchItems.coerceAtLeast(0)
        if(!ready||requested==identity)return false
        requested=identity
        return true
    }
}
