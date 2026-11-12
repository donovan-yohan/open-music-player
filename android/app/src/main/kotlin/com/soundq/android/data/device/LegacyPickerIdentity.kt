package com.soundq.android.data.device

/** Where the object behind a row an older build's file/folder picker keyed can be looked up now. */
internal sealed interface LegacyRoute {
    /** A MediaStore row, reached through whichever collection the picker used. */
    data class Media(val uri: String) : LegacyRoute
    /** A shared-storage file. An external-storage document id is its path, so the path is its identity. */
    data class Path(val path: String) : LegacyRoute
}

/** Reads the provider object keys older builds stored for picked files: `media:<version>:<uri>:<generation>`
 * (API 30+), `provider:<uri>` and `document:<authority>:<document id>`. Pure; it proves nothing by itself. */
internal object LegacyPickerIdentity {
    private const val EXTERNAL_STORAGE = "com.android.externalstorage.documents"
    private const val DOWNLOADS = "com.android.providers.downloads.documents"
    private const val MEDIA_DOCUMENTS = "com.android.providers.media.documents"

    /** [root] maps an external-storage volume id (`primary`, `1A2B-3C4D`) to its mounted directory. */
    fun route(objectId: String, root: (String) -> String): LegacyRoute? = when {
        objectId.startsWith("media:") -> {
            val start = objectId.indexOf("content://media/")
            val end = objectId.lastIndexOf(':')
            if (start < 0 || end <= start || objectId.substring(end + 1).toLongOrNull() == null) null
            else LegacyRoute.Media(objectId.substring(start, end))
        }
        objectId.startsWith("provider:content://media/") -> LegacyRoute.Media(objectId.removePrefix("provider:"))
        objectId.startsWith("document:") -> {
            val rest = objectId.removePrefix("document:")
            val authority = rest.substringBefore(':', "")
            document(authority, rest.substringAfter(':', ""), root)
        }
        else -> null
    }

    private fun document(authority: String, id: String, root: (String) -> String): LegacyRoute? {
        if (id.isEmpty()) return null
        return when (authority) {
            EXTERNAL_STORAGE -> {
                val volume = id.substringBefore(':', "")
                val relative = id.substringAfter(':', "").trim('/')
                if (volume.isEmpty() || relative.isEmpty()) null else path(root(volume) + "/" + relative)
            }
            DOWNLOADS -> when {
                id.startsWith("raw:") -> path(id.removePrefix("raw:"))
                id.startsWith("msf:") -> id.removePrefix("msf:").toLongOrNull()?.takeIf { it >= 0 }?.let { LegacyRoute.Media("content://media/external/file/$it") }
                else -> null
            }
            MEDIA_DOCUMENTS -> if (id.startsWith("audio:")) id.removePrefix("audio:").toLongOrNull()?.takeIf { it >= 0 }?.let { LegacyRoute.Media("content://media/external/audio/media/$it") } else null
            else -> null
        }
    }

    private fun path(value: String): LegacyRoute.Path? =
        value.takeIf { it.startsWith("/") && it.split('/').none { part -> part == ".." || part == "." } }?.let(LegacyRoute::Path)
}
