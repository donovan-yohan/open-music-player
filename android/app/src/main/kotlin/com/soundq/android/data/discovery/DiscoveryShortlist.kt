package com.soundq.android.data.discovery

import java.text.Normalizer
import java.util.Locale

/** Comparable lexical evidence only; provider order breaks ties within the arriving batch. */
internal class DiscoveryShortlist(query: String) {
    private val queryTitle = tokens(query)
    private val queryTerms = queryTitle.toSet()

    fun from(rows: List<DiscoveryResultRow>): List<DiscoveryResultRow> {
        val matches = rows.map { it to band(it) }.filter { (_, band) -> band != Band.None }
        // A provider can have relevant aliases/recommendations that aren't lexical matches.
        // Show one such fallback if this batch has no evidence; typed views keep every row.
        return if (matches.isEmpty()) rows.take(1)
        else matches.sortedBy { it.second }.take(MAX_PER_BATCH).map { it.first }
    }

    private fun band(row: DiscoveryResultRow): Band {
        if (queryTerms.isEmpty()) return Band.None
        val (title, credit) = when (row) {
            is DiscoveryResultRow.Source -> row.row.title to row.row.artist
            is DiscoveryResultRow.Entity -> row.entity.title to row.entity.artist
        }
        val titleTokens = tokens(title)
        if (titleTokens == queryTitle) return Band.ExactTitle
        val titleTerms = titleTokens.toSet()
        if (titleTerms.containsAll(queryTerms)) return Band.TitleTokens
        val creditTerms = tokens(credit).toSet()
        if (queryTerms.any(titleTerms::contains)) {
            return if (queryTerms.all { it in titleTerms || it in creditTerms }) Band.TitleAndCredit else Band.PartialTitle
        }
        return if (queryTerms.any(creditTerms::contains)) Band.CreditOnly else Band.None
    }

    private enum class Band { ExactTitle, TitleTokens, TitleAndCredit, PartialTitle, CreditOnly, None }

    private companion object {
        const val MAX_PER_BATCH = 3
        val word = Regex("[\\p{L}\\p{N}][\\p{L}\\p{N}\\p{M}]*")
        fun tokens(value: String): List<String> = word.findAll(Normalizer.normalize(value, Normalizer.Form.NFKC).lowercase(Locale.ROOT))
            .map { it.value }.toList()
    }
}
