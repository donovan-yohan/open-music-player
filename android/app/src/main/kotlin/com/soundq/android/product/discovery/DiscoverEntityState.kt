package com.soundq.android.product.discovery

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.*
import androidx.compose.ui.text.input.TextFieldValue
import com.soundq.android.data.catalog.ArtistMbid
import com.soundq.android.data.catalog.ReleaseGroupMbid
import com.soundq.android.data.discovery.*
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine

/** A new visit is made on Back, query replacement and foreground return, even to the same ID. */
internal class EntityBrowseVisit(private val origin: () -> Boolean) {
    private val live = AtomicBoolean(true)
    private val registry = DiscoveryCalls()
    fun current() = live.get() && origin()
    fun retire() { live.set(false); registry.cancel() }

    suspend fun <T> read(fetch: (DiscoveryCalls, () -> Boolean) -> T): T = suspendCancellableCoroutine { continuation ->
        val calls = DiscoveryCalls()
        val cancel: () -> Unit = { continuation.cancel() }
        continuation.invokeOnCancellation { calls.cancel() }
        if (!registry.track(cancel)) {
            continuation.cancel()
        } else Dispatchers.IO.dispatch(continuation.context, Runnable {
            fun valid() = continuation.isActive && current()
            try {
                if (!valid()) { continuation.cancel(); return@Runnable }
                val result = runCatching { fetch(calls, ::valid) }
                if (valid()) continuation.resumeWith(result) else continuation.cancel()
            } finally { registry.untrack(cancel) }
        })
    }
}

/** Keep accepted rows and the upstream cursor on retirement; only the still-demanded read restarts. */
internal class EntityBrowseSlot<T>(private val identity: (T) -> Any) {
    var rows by mutableStateOf<List<T>>(emptyList())
        private set
    var accepted by mutableStateOf(false)
        private set
    var failed by mutableStateOf(false)
        private set
    var truncated by mutableStateOf(false)
        private set
    var next by mutableStateOf<Int?>(0)
        private set
    private var epoch by mutableIntStateOf(0)
    private var demand by mutableStateOf(true)
    private var reader: Any? = null
    val revision get() = epoch
    val waiting get() = demand && !failed
    val canContinue get() = accepted && next != null

    fun request() {
        if (waiting || next == null) return
        failed = false
        demand = true
        epoch++
    }

    suspend fun load(visit: EntityBrowseVisit, debounce: Boolean,
        fetch: (Int, DiscoveryCalls, () -> Boolean) -> DiscoverBrowsePage<T>,
        onAccepted: (DiscoverBrowsePage<T>, Int) -> Unit,
    ) {
        val offset = next ?: return
        if (!demand || !visit.current()) return
        val ticket = Any().also { reader = it }
        try {
            if (debounce && offset == 0 && !accepted && epoch == 0) delay(350)
            val page = visit.read { calls, current -> fetch(offset, calls, current) }
            if (reader !== ticket || !visit.current()) return
            rows = (rows + page.rows).distinctBy(identity)
            next = page.nextOffset
            truncated = page.truncated
            accepted = true
            demand = false
            onAccepted(page, offset)
        } catch (error: CancellationException) { throw error }
          catch (_: Exception) {
            // Auth may reject a read attempt without retiring its visit (for example,
            // if its queued bearer changed). Leave the page retryable, not loading.
            if (reader === ticket && visit.current()) {
                demand = false
                failed = true
            }
        } finally { if (reader === ticket) reader = null }
    }
}

@Composable internal fun <T> EntityBrowseRead(slot: EntityBrowseSlot<T>, visit: EntityBrowseVisit?,
    debounce: Boolean = false, onAccepted: (DiscoverBrowsePage<T>, Int) -> Unit = { _, _ -> },
    fetch: (Int, DiscoveryCalls, () -> Boolean) -> DiscoverBrowsePage<T>,
) {
    LaunchedEffect(visit, slot, slot.revision) {
        if (visit != null) slot.load(visit, debounce, fetch, onAccepted)
    }
}

private typealias ReleaseSlot = EntityBrowseSlot<DiscoverReleaseGroupRow>
private typealias SongSlot = EntityBrowseSlot<DiscoverBrowseSong>

internal class EntityArtist(val id: ArtistMbid, val name: String, val description: String? = null) : EntityDestination("Artist") {
    var editor by mutableStateOf(TextFieldValue())
        private set
    var search by mutableStateOf<EntityArtistSearch?>(null)
        private set
    val albums = ReleaseSlot { it.id }
    val singles = ReleaseSlot { it.id }
    val eps = ReleaseSlot { it.id }
    val top = SongSlot { it.recording }
    val scroll get() = search?.scroll ?: overviewScroll
    private val overviewScroll = LazyListState()

    /** Composition-only changes don't replace the scoped query or its pending work. */
    fun edit(value: TextFieldValue): Boolean {
        editor = value
        val query = value.text.trim().takeIf { it.isNotEmpty() }
        if (query == search?.query) return false
        search = query?.let(::EntityArtistSearch)
        return true
    }
}

internal class EntityArtistSearch(val query: String) {
    val songs = SongSlot { it.recording }
    val albums = ReleaseSlot { it.id }
    val scroll = LazyListState()
}

internal class EntityAlbum(val group: ReleaseGroupMbid, val name: String, val artist: String?, val releaseInfo: String?) : EntityDestination("Album") {
    val editions = EntityBrowseSlot<DiscoverBrowseEdition> { it.id }
    var trackPage by mutableStateOf<EntityTrackPage?>(null)
        private set
    val unselectedScroll = LazyListState()
    fun select(edition: DiscoverBrowseEdition) {
        if (edition.group == group && trackPage?.edition?.id != edition.id) trackPage = EntityTrackPage(edition)
    }
}

internal class EntityTrackPage(val edition: DiscoverBrowseEdition) {
    val details = EntityBrowseSlot<DiscoverBrowseTracklist> { it.edition.id }
    val scroll = LazyListState()
}

internal enum class EntityShelf(val label: String) { Top("Top tracks"), Albums("Albums"), Singles("Singles & EPs") }
internal sealed class EntityDestination(val label: String) {
    class Shelf(val artist: EntityArtist, val kind: EntityShelf) : EntityDestination(kind.label) { val scroll = LazyListState() }
    class Editions(val album: EntityAlbum) : EntityDestination("Editions") { val scroll = LazyListState() }
}

/** Retention is local to this nested stack. The parent retains root Discover independently. */
internal class EntityBrowseNavigation(initial: EntityDestination, private val origin: () -> Boolean) {
    private val stack = mutableListOf(initial)
    var destination by mutableStateOf(initial)
        private set
    var visit by mutableStateOf<EntityBrowseVisit?>(null)
        private set
    private var resumed = false
    private var surfaceCurrent: () -> Boolean = { true }

    fun setResumed(next: Boolean, surface: () -> Boolean = { true }) {
        if (resumed == next) return
        resumed = next
        surfaceCurrent = surface
        renew()
    }
    fun renew() {
        visit?.retire()
        val surface = surfaceCurrent
        visit = if (resumed && origin() && surface()) EntityBrowseVisit { surface() && origin() } else null
    }
    fun push(next: EntityDestination) {
        if (visit?.current() != true) return
        visit?.retire()
        stack.add(next)
        destination = next
        renew()
    }
    fun artist(credit: DiscoverArtistCredit) {
        if (visit?.current() != true) return
        if (stack.filterIsInstance<EntityArtist>().lastOrNull()?.id == credit.id) {
            visit?.retire()
            while ((stack.lastOrNull() as? EntityArtist)?.id != credit.id) stack.removeAt(stack.lastIndex)
            destination = stack.last()
            renew()
        } else push(EntityArtist(credit.id, credit.name))
    }
    fun back(onExit: () -> Unit) {
        visit?.retire()
        val artist = destination as? EntityArtist
        if (artist?.search != null) {
            artist.edit(TextFieldValue())
            renew()
            return
        }
        if (stack.size <= 1) { visit = null; onExit(); return }
        stack.removeAt(stack.lastIndex)
        destination = stack.last()
        renew()
    }
}
