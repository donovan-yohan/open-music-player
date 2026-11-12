package com.soundq.android.data.deviceaudio

/** Folds stored rows the provider proved are one object into a single row. Pure and deterministic.
 *
 * Survivor: the row already under the published key, else the lowest row id. Aliases are united.
 * Listening history ([after]): the latest play time wins; the resume state (bookmark, completion) comes from
 * the most recently played row (ties keep the survivor's), falling back to the other row's bookmark when
 * that row has none. A bookmark moves only if it belonged to the retired row's content and that content is
 * what the survivor now holds; otherwise it was already unusable. Each retired row id stays resolvable to
 * the survivor for the exact content it named, so saved queues keep playing it. Per-track listening speed
 * is keyed by content, not row id, so it is shared by construction. */
internal class IdentityFold private constructor(val files: List<DeviceAudio>, val merges: List<Merge>) {
    internal data class Merge(val survivor: DeviceFileId, val retired: List<DeviceAudio>)

    fun after(files: List<DeviceAudio>, journal: List<JournalEntry>, retired: List<RetiredDeviceIdentity>): Pair<List<JournalEntry>, List<RetiredDeviceIdentity>> {
        var history = journal
        var redirects = retired
        for (merge in merges) {
            val survivor = files.single { it.id == merge.survivor }
            val key = HistoryKey.Device(survivor.id)
            for (old in merge.retired) {
                val oldKey = HistoryKey.Device(old.id)
                val moved = history.find { it.key == oldKey }?.let { entry ->
                    val bookmark = entry.bookmark?.takeIf { it.owner == old.owner && old.revision == survivor.revision }?.let { Bookmark(survivor.owner, it.positionMs) }
                    entry.copy(key = key, bookmark = bookmark)
                }
                val merged = combine(history.find { it.key == key }, moved)
                history = history.filterNot { it.key == oldKey || it.key == key } + listOfNotNull(merged)
                redirects = redirects.map { if (it.into == old.id) it.copy(into = survivor.id) else it } + RetiredDeviceIdentity(old.owner, survivor.id)
            }
        }
        val ids = files.map { it.id }.toSet()
        redirects = redirects.filter { (it.from.key as HistoryKey.Device).id !in ids && it.into in ids }.distinctBy { it.from.key }.takeLast(DomainFile.MAX_RECORDS)
        return history to redirects
    }

    companion object {
        fun before(files: List<DeviceAudio>, audio: List<DiscoveredAudio>): IdentityFold {
            val published = audio.map { it.objectId }.toSet()
            // A former key that is itself published in this scan is a different object, never a fold.
            val formers = audio.groupBy { it.objectId }.mapValues { (id, rows) -> rows.flatMap { it.formerObjectIds }.toSet() - published - id }
            var rows = files
            val merges = mutableListOf<Merge>()
            for ((id, former) in formers) {
                if (former.isEmpty()) continue
                val legacy = rows.filter { it.objectId in former }.sortedBy { it.id.value.toString() }
                if (legacy.isEmpty()) continue
                val members = listOfNotNull(rows.find { it.objectId == id }) + legacy
                val survivor = members.first()
                val retired = members.drop(1)
                val folded = survivor.copy(objectId = id, aliases = (survivor.aliases + retired.flatMap { it.aliases }).distinctBy { it.grantId to it.locator })
                val gone = retired.map { it.id }.toSet()
                rows = rows.filterNot { it.id in gone }.map { if (it.id == survivor.id) folded else it }
                if (retired.isNotEmpty()) merges += Merge(survivor.id, retired)
            }
            return IdentityFold(rows, merges)
        }

        /** [kept] belongs to the survivor; [moved] is the retired row's entry already keyed to the survivor. */
        internal fun combine(kept: JournalEntry?, moved: JournalEntry?): JournalEntry? {
            if (kept == null || moved == null) return kept ?: moved
            val latest = if ((moved.playedAt ?: -1) > (kept.playedAt ?: -1)) moved else kept
            val other = if (latest === moved) kept else moved
            val playedAt = listOfNotNull(kept.playedAt, moved.playedAt).maxOrNull()
            return latest.copy(key = kept.key, playedAt = playedAt, bookmark = if (latest.completed) null else latest.bookmark ?: other.bookmark)
        }
    }
}
