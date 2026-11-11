package com.soundq.android.product.home

import com.soundq.android.data.home.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** One signed-in shell incarnation; disposal permanently retires its callbacks. */
class HomeShell(valid: () -> Boolean = { true }) : AutoCloseable {
    private val lifetime = HomeRouteLifetime(valid)
    private val mutable = MutableStateFlow(lifetime.enter(HomeDestination.Library))
    val route: StateFlow<HomeRoute> = mutable
    fun navigate(destination: HomeDestination) { if(mutable.value.current() && mutable.value.destination != destination) mutable.value=lifetime.enter(destination) }
    override fun close() { lifetime.close() }
}
