package com.soundq.android.product.artwork

import kotlinx.coroutines.*
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

/** Speculation uses one of the existing permits, never another reader. Demand can overtake
 * queued speculation; an already running original read is reused, not restarted on entry.
 * Cancellation keeps both permits charged until the actual blocking read returns.
 */
internal class ThumbnailReadGate(private val readers:Semaphore) {
    private val speculative=Semaphore(1)
    suspend fun <T> read(visible:Boolean,awaitVisible:suspend ()->Unit,block:suspend ()->T):T {
        if(visible)return readers.withPermit {block()}
        return coroutineScope {
            val lock=Any()
            var demanded=false
            var running=false
            val work=async(start=CoroutineStart.UNDISPATCHED) {
                speculative.withPermit {readers.withPermit {
                    val proceed=synchronized(lock) {if(demanded)false else {running=true;true}}
                    if(proceed)Result.success(block()) else null
                }}
            }
            val demand=async(start=CoroutineStart.UNDISPATCHED) {awaitVisible()}
            try {
                select<T> {
                    work.onAwait {it!!.getOrThrow()}
                    demand.onAwait {
                        val started=synchronized(lock) {demanded=true;running}
                        if(started)work.await()!!.getOrThrow()
                        else {work.cancelAndJoin();readers.withPermit {block()}}
                    }
                }
            } finally {demand.cancel();work.cancel()}
        }
    }
}
