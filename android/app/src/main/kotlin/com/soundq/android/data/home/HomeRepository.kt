package com.soundq.android.data.home

import com.soundq.android.data.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

data class HomeEntry(val track: Track, val eligible: Boolean)
data class HistoryEntry(val id: Long, val entry: HomeEntry, val playedAt: java.time.Instant, val contextType: String?, val contextId: String?, val skipped: Boolean)
data class HomeReadState(
    val rows: List<HomeEntry> = emptyList(),
    val loading: Boolean = false,
    val error: SafeFailure.Reason? = null,
)
class HomeRepository(
    private val session: AccountSession,
    private val fetch: (AccountScope) -> List<HomeEntry>,
) {
    private val mutable = MutableStateFlow(HomeReadState())
    val state: StateFlow<HomeReadState> = mutable
    private var generation = 0L
    fun refreshRecent() {
        val scope = session.capture() ?: return retire()
        val version = synchronized(this) {
            generation++
            mutable.value = mutable.value.copy(loading = true, error = null)
            generation
        }
        try {
            session.checkScope(scope)
            val rows = fetch(scope)
            synchronized(this) {
                if (generation == version && session.current(scope)) mutable.value = HomeReadState(rows = rows)
            }
        } catch (error: Exception) {
            synchronized(this) {
                if (generation == version && session.current(scope)) mutable.value = mutable.value.copy(
                    loading = false, error = (error as? SafeFailure)?.reason ?: SafeFailure.Reason.Network,
                )
            }
        }
    }
    @Synchronized fun retire() { generation++; mutable.value = HomeReadState() }
}
