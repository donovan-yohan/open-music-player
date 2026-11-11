package com.soundq.android.product

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.*
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.soundq.android.data.LibraryState
import kotlinx.coroutines.flow.collect

private data class LibraryViewport(val library:LibraryState,val lastVisible:Int,val totalItems:Int)

/**
 * Observe the existing list, never create another paging or row owner.
 * current must include the originating account/route and exclude covered panels.
 * onLoadMore must synchronously claim library before scheduling its IO.
 */
@Composable internal fun LibraryNearBottomPagination(
    listState:LazyListState,
    library:LibraryState,
    requestIdentity:Any,
    enabled:Boolean,
    current:()->Boolean,
    onLoadMore:(LibraryState,()->Boolean)->Unit,
    prefetchItems:Int=5,
) {
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    var visit by remember(lifecycle){mutableLongStateOf(0L)}
    val gate=remember(requestIdentity,enabled,lifecycle,visit){LibraryPaginationGate()}
    val latestGate by rememberUpdatedState(gate)
    val latestLibrary by rememberUpdatedState(library)
    val latestEnabled by rememberUpdatedState(enabled)
    val latestCurrent by rememberUpdatedState(current)
    val latestLoad by rememberUpdatedState(onLoadMore)
    val latestPrefetch by rememberUpdatedState(prefetchItems)
    val admitted=remember(gate){{gate.current()&&latestEnabled&&lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)&&latestCurrent()}}
    DisposableEffect(gate){onDispose {gate.close()}}
    DisposableEffect(lifecycle) {
        // addObserver synchronously replays ON_RESUME for an already resumed
        // owner. That catch-up is not a new visit and must not renew a claimed page.
        var resumed=lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
        val observer=LifecycleEventObserver {_,event->when(event) {
            Lifecycle.Event.ON_PAUSE,Lifecycle.Event.ON_STOP,Lifecycle.Event.ON_DESTROY->{resumed=false;latestGate.close()}
            Lifecycle.Event.ON_RESUME->{if(!resumed)visit++;resumed=true}
            else->Unit
        }}
        lifecycle.addObserver(observer)
        onDispose {lifecycle.removeObserver(observer)}
    }
    LaunchedEffect(listState,gate) {
        snapshotFlow {
            val layout=listState.layoutInfo
            LibraryViewport(latestLibrary,layout.visibleItemsInfo.lastOrNull()?.index ?: -1,layout.totalItemsCount)
        }.collect {viewport->
            if(admitted()&&gate.claim(viewport.library,viewport.lastVisible,viewport.totalItems,latestPrefetch)) {
                latestLoad(viewport.library,admitted)
            }
        }
    }
}
