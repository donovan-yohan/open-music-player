package com.soundq.android.product.trackdetails

import com.soundq.android.data.preferences.KeyNotation
import java.util.Locale

/** Formats existing independent facts only. Never infers a key or changes corrections. */
internal fun formatAnalysisKey(musicalKey:String?,camelot:String?,keyNotation:KeyNotation=KeyNotation.Camelot):String? {
    val musical=musicalKey?.trim()?.takeIf {it.isNotEmpty()}
    val wheel=camelot?.trim()?.uppercase(Locale.ROOT)?.takeIf {Regex("(?:[1-9]|1[0-2])[AB]").matches(it)}
    return when(keyNotation) {KeyNotation.Camelot->wheel?:musical;KeyNotation.Musical->musical?:wheel}
}
