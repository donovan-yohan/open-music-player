package com.soundq.android.data

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainCoroutineDispatcher
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

/** Observation only; AccountSession remains the synchronous capability authority. */
internal data class AccountObservation(val state:AuthState,val revision:Long)

/** Never re-enter repository monitors inline under account publication. A
 * revision invalidates equal terminal auth after an undrained lock/unlock;
 * observe current atomic truth, not a queued stale cleanup instruction. */
internal fun CoroutineScope.observeAccountState(
    session:AccountSession,
    dispatcher:MainCoroutineDispatcher=Dispatchers.Main,
    observed:suspend (AccountObservation)->Unit,
):Job=launch(dispatcher) {
    combine(session.state,session.scopeRevision){_,_->session.observation()}.distinctUntilChanged().collect { (state,revision) ->
        observed(AccountObservation(state,revision))
    }
}
