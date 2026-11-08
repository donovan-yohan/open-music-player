package com.soundq.android.data.home

/** A mounted shell incarnation, not just a destination name; A→B→A never revives A. */
enum class HomeDestination { Library, Home, History }
class HomeRouteLifetime(private val valid: () -> Boolean = { true }) : AutoCloseable {
    private var epoch = 0L
    private var closed = false
    @Synchronized fun enter(destination: HomeDestination): HomeRoute = HomeRoute(this, ++epoch, destination)
    @Synchronized internal fun current(route: HomeRoute): Boolean = !closed && route.epoch == epoch && valid()
    @Synchronized override fun close() { closed = true; epoch++ }
}
class HomeRoute internal constructor(private val owner: HomeRouteLifetime, internal val epoch: Long, val destination: HomeDestination) {
    fun current() = owner.current(this)
}
