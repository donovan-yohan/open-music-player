package com.soundq.android.data.deviceaudio

/** Own the backing copy; neither mutable builders nor a mutable cast escape. */
internal open class PublishedList<T>(values: List<T>) : AbstractList<T>(), java.util.RandomAccess {
    private val values = ArrayList(values)
    override val size: Int get() = values.size
    override fun get(index: Int): T = values[index]
}

/** The marker guarantees that every alias list is sealed as well as the outer rows. */
internal class PublishedDeviceRows(rows: List<DeviceAudio>) : PublishedList<DeviceAudio>(
    rows.map { it.copy(aliases = PublishedList(it.aliases)) },
)

/** Snapshot-local, eager, single-hop lookup. No query cache or retained snapshot history.
 * Hash lookup is expected constant work, not a worst-case real-time guarantee.
 * Multiplicity is retained even for identical duplicates: null means ambiguous/missing.
 */
internal class PublishedSourceLookup(files: List<DeviceAudio>, retired: List<RetiredDeviceIdentity>) {
    private class Unique<K, V : Any> {
        private val values = HashMap<K, V?>()
        fun add(key: K, value: V) { values[key] = if (values.containsKey(key)) null else value }
        operator fun get(key: K): V? = values[key]
    }
    private class Row(val value: DeviceAudio) { val available = value.available }
    private val direct = Unique<DeviceFileId, Row>()
    private val folds = Unique<ContentOwner, DeviceFileId>()
    private val hasRetired = retired.isNotEmpty()
    private val retained = HashMap<DeviceFileId, Unique<ContentRevision, Row>>()
    private val available = HashMap<DeviceFileId, Unique<ContentRevision, Row>>()
    init {
        for (file in files) {
            val row = Row(file)
            direct.add(file.id, row)
            retained.getOrPut(file.id) { Unique() }.add(file.revision, row)
            if (row.available) available.getOrPut(file.id) { Unique() }.add(file.revision, row)
        }
        for (fold in retired) folds.add(fold.from, fold.into)
    }
    fun authorityTarget(owner: ContentOwner): DeviceFileId? = folds[owner]

    fun resolve(owner: ContentOwner, availableOnly: Boolean): DeviceAudio? {
        val id = (owner.key as HistoryKey.Device).id
        direct[id]?.let { return direct(it, owner.revision, owner.incarnation, availableOnly) }
        return folded(owner, availableOnly)
    }
    // Keep the original direct-first validation order for arbitrary domain callers.
    fun resolve(id: DeviceFileId, revision: ContentRevision, incarnation: Long, availableOnly: Boolean): DeviceAudio? {
        direct[id]?.let { return direct(it, revision, incarnation, availableOnly) }
        // Legacy scan constructs an owner only when it visits a retirement row.
        if (!hasRetired) return null
        return folded(ContentOwner(HistoryKey.Device(id), revision, incarnation), availableOnly)
    }
    private fun direct(row: Row, revision: ContentRevision, incarnation: Long, availableOnly: Boolean): DeviceAudio? =
        row.value.takeIf { it.revision == revision && it.incarnation == incarnation && (!availableOnly || row.available) }

    private fun folded(owner: ContentOwner, availableOnly: Boolean): DeviceAudio? {
        val target = folds[owner] ?: return null
        // Deliberately match target ID + full revision + availability, NOT incarnation.
        return (if (availableOnly) available else retained)[target]?.get(owner.revision)?.value
    }
}
