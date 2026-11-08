package com.soundq.android.product

import java.util.concurrent.atomic.AtomicBoolean

/** A mounted Library visit cannot revive after route/lifecycle or same-ID replacement ABA. */
internal class LibraryRowLifetime(private val mounted:()->Boolean) {
    private val alive=AtomicBoolean(true)
    fun current():Boolean=alive.get()&&mounted()
    fun close() {alive.set(false)}
}
internal class RowIdentity(private val value:Any) {
    override fun equals(other:Any?)=other is RowIdentity&&other.value===value
    override fun hashCode()=System.identityHashCode(value)
}
