package com.soundq.android.product.playlists

/** UI-only draft; never a saved dispatch capability or a creation acknowledgement. */
internal data class PlaylistCreateForm(val name: String = "", val description: String = "", val open: Boolean = false)
internal fun saveCreateForm(endpoint: String, account: String, value: PlaylistCreateForm): List<String> =
    listOf("playlist-create:1", endpoint, account, value.name, value.description, value.open.toString())
internal fun restoreCreateForm(endpoint: String, account: String, payload: List<*>): PlaylistCreateForm? {
    if (payload.size != 6 || payload[0] != "playlist-create:1" || payload[1] != endpoint || payload[2] != account) return null
    val name = payload[3] as? String ?: return null
    val description = payload[4] as? String ?: return null
    val open = (payload[5] as? String)?.toBooleanStrictOrNull() ?: return null
    return PlaylistCreateForm(name, description, open)
}
