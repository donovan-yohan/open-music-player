package com.soundq.android.data.deviceaudio

import java.io.File
import java.io.FileOutputStream
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.util.UUID
import kotlinx.serialization.json.*

internal data class JournalEntry(
    val key: HistoryKey, val playedAt: Long? = null, val bookmark: Bookmark? = null,
    val traversal: UUID? = null, val sequence: Long = 0, val completed: Boolean = false,
)
internal data class ServerContent(val owner: ContentOwner, val durationMs: Long)
internal data class DomainState(
    val revision: Long = 0, val grants: List<ScanGrant> = emptyList(), val files: List<DeviceAudio> = emptyList(),
    val servers: List<ServerContent> = emptyList(), val journal: List<JournalEntry> = emptyList(),
)

/** The only persistence owner. Lifetime OS lock excludes another writer, including same-process handles.
 * No recovery-by-empty on rejected data. Publication is fsynced stage + atomic replacement + directory
 * force. Unsupported atomic/force or ambiguous IO fails closed until close/reopen. */
internal class DomainFile(private val file: File, private val commitFault: (String) -> Unit = {}) : AutoCloseable {
    // Room for 20k ordinary locator/metadata/alias rows, still a bounded local document.
    companion object { const val MAX_BYTES = 32 * 1024 * 1024; const val MAX_RECORDS = 20000 }
    private val channel: FileChannel
    private val lock: java.nio.channels.FileLock
    private var expected: ByteArray? = null
    var rejected = false
        private set
    var state = DomainState()
        private set
    init {
        require(!Files.isSymbolicLink(file.toPath()))
        file.absoluteFile.parentFile.mkdirs()
        channel = FileChannel.open(File(file.absoluteFile.parentFile, file.name + ".lock").toPath(), StandardOpenOption.CREATE, StandardOpenOption.WRITE)
        try { lock = requireNotNull(channel.tryLock()) { "Device listening store already owned" } }
        catch (e: Exception) { channel.close(); throw e }
        try { expected = read(); state = expected?.let(::decodeDomain) ?: DomainState() }
        catch (_: Exception) { rejected = true }
    }
    private fun read(): ByteArray? {
        if (!file.exists()) return null
        require(!Files.isSymbolicLink(file.toPath()) && file.length() <= MAX_BYTES)
        return file.inputStream().use { input ->
            val out = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val n = input.read(buffer); if (n < 0) break
                require(out.size().toLong() + n <= MAX_BYTES); out.write(buffer, 0, n)
            }
            out.toByteArray()
        }
    }
    fun intact(): Boolean {
        if (rejected) return false
        return try {
            val now = read()
            val equal = if (now == null) expected == null else expected?.contentEquals(now) == true
            if (!equal) rejected = true
            equal
        } catch (_: Exception) { rejected = true; false }
    }
    fun commit(candidate: DomainState): Boolean {
        if (!intact()) return false
        val next = candidate.copy(revision = Math.addExact(state.revision, 1))
        val bytes = encodeDomain(next).toString().toByteArray(Charsets.UTF_8)
        require(bytes.size <= MAX_BYTES)
        // Validate the same strict decoder used after process restart before publishing anything.
        require(decodeDomain(bytes) == next)
        val stage = File.createTempFile("device-listening-", ".stage", file.absoluteFile.parentFile)
        try {
            FileOutputStream(stage).use { it.write(bytes); it.fd.sync() }
            commitFault("beforeReplace")
            if (!intact()) return false
            Files.move(stage.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            commitFault("afterReplace")
            FileChannel.open(file.absoluteFile.parentFile.toPath(), StandardOpenOption.READ).use { it.force(true) }
            expected = bytes; state = next
            return true
        } catch (e: Exception) { rejected = true; throw e }
        finally { stage.delete() }
    }
    override fun close() { try { lock.release() } finally { channel.close() } }
}

private fun obj(vararg values: Pair<String, JsonElement>) = JsonObject(linkedMapOf(*values))
private fun s(v: String) = JsonPrimitive(v)
private fun n(v: Long) = JsonPrimitive(v)
private fun b(v: Boolean) = JsonPrimitive(v)
private fun nullable(v: String?) = v?.let(::s) ?: JsonNull
private fun revision(v: ContentRevision) = obj("sha256" to s(v.sha256), "bytes" to n(v.byteLength))
private fun locator(v: ProviderLocator) = obj("provider" to s(v.provider), "value" to s(v.value))
private fun key(v: HistoryKey): JsonObject = when (v) {
    is HistoryKey.Device -> obj("type" to s("device"), "id" to s(v.id.value.toString()))
    is HistoryKey.Server -> obj("type" to s("server"), "endpoint" to s(v.scope.endpoint), "account" to s(v.scope.account), "id" to n(v.id.value))
}
private fun owner(v: ContentOwner) = obj("key" to key(v.key), "revision" to revision(v.revision), "incarnation" to n(v.incarnation))
internal fun encodeDomain(v: DomainState): JsonObject = obj(
    "version" to n(1), "revision" to n(v.revision),
    "grants" to JsonArray(v.grants.map { g -> obj("id" to s(g.id.value.toString()), "kind" to s(g.kind.name), "label" to s(g.label), "locator" to locator(g.locator), "persisted" to b(g.persisted), "state" to s(g.state.name)) }),
    "files" to JsonArray(v.files.map { f -> obj(
        "id" to s(f.id.value.toString()), "provider" to s(f.objectId.provider), "objectId" to s(f.objectId.objectId), "revision" to revision(f.revision), "incarnation" to n(f.incarnation),
        "metadata" to obj("filename" to s(f.metadata.filename), "title" to nullable(f.metadata.title), "artist" to nullable(f.metadata.artist), "album" to nullable(f.metadata.album), "artwork" to nullable(f.metadata.artworkReference)),
        "durationMs" to (f.durationMs?.let(::n) ?: JsonNull),
        "aliases" to JsonArray(f.aliases.map { a -> obj("grant" to s(a.grantId.value.toString()), "locator" to locator(a.locator), "state" to s(a.state.name)) }),
    ) }),
    "servers" to JsonArray(v.servers.map { obj("owner" to owner(it.owner), "durationMs" to n(it.durationMs)) }),
    "journal" to JsonArray(v.journal.map { j -> obj("key" to key(j.key), "playedAt" to (j.playedAt?.let(::n) ?: JsonNull),
        "bookmark" to (j.bookmark?.let { obj("owner" to owner(it.owner), "positionMs" to n(it.positionMs)) } ?: JsonNull),
        "traversal" to nullable(j.traversal?.toString()), "sequence" to n(j.sequence), "completed" to b(j.completed)) }),
)
private fun JsonObject.text(k: String) = getValue(k).jsonPrimitive.also { require(it.isString) }.content
private fun JsonObject.long(k: String) = getValue(k).jsonPrimitive.also { require(!it.isString) }.long
private fun JsonObject.boolean(k: String) = getValue(k).jsonPrimitive.also { require(!it.isString) }.boolean
private fun JsonObject.maybeText(k: String) = if (getValue(k) == JsonNull) null else text(k)
private fun JsonObject.maybeLong(k: String) = if (getValue(k) == JsonNull) null else long(k)
private fun JsonObject.objects(k: String) = getValue(k).jsonArray.also { require(it.size <= DomainFile.MAX_RECORDS) }.map { it.jsonObject }
private fun JsonObject.locator(k: String): ProviderLocator = getValue(k).jsonObject.let { ProviderLocator(it.text("provider"), it.text("value")) }
private fun JsonObject.revision(k: String): ContentRevision = getValue(k).jsonObject.let { ContentRevision(it.text("sha256"), it.long("bytes")) }
private fun JsonObject.key(k: String): HistoryKey = getValue(k).jsonObject.let {
    when (it.text("type")) {
        "device" -> HistoryKey.Device(DeviceFileId(UUID.fromString(it.text("id"))))
        "server" -> HistoryKey.Server(ServerAccount(it.text("endpoint"), it.text("account")), ServerAudioId(it.long("id")))
        else -> error("Unknown history namespace")
    }
}
private fun JsonObject.owner(k: String): ContentOwner = getValue(k).jsonObject.let { ContentOwner(it.key("key"), it.revision("revision"), it.long("incarnation")) }
internal fun decodeDomain(bytes: ByteArray): DomainState {
    require(bytes.size <= DomainFile.MAX_BYTES)
    val root = Json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
    require(root.long("version") == 1L)
    val state = DomainState(
        root.long("revision").also { require(it >= 0) },
        root.objects("grants").map { ScanGrant(ScanGrantId(UUID.fromString(it.text("id"))), GrantKind.valueOf(it.text("kind")), it.text("label"), it.locator("locator"), it.boolean("persisted"), AccessState.valueOf(it.text("state"))) },
        root.objects("files").map { f -> DeviceAudio(DeviceFileId(UUID.fromString(f.text("id"))), ProviderObjectId(f.text("provider"), f.text("objectId")), f.revision("revision"), f.long("incarnation").also { require(it > 0) },
            f.getValue("metadata").jsonObject.let { OriginalMetadata(it.text("filename"), it.maybeText("title"), it.maybeText("artist"), it.maybeText("album"), it.maybeText("artwork")) },
            f.maybeLong("durationMs").also { require(it == null || it > 0) }, f.objects("aliases").map { LocatorAccess(ScanGrantId(UUID.fromString(it.text("grant"))), it.locator("locator"), AccessState.valueOf(it.text("state"))) }) },
        root.objects("servers").map { ServerContent(it.owner("owner"), it.long("durationMs").also { require(it > 0) }).also { require(it.owner.key is HistoryKey.Server) } },
        root.objects("journal").map { j -> JournalEntry(j.key("key"), j.maybeLong("playedAt").also { require(it == null || it >= 0) },
            if (j.getValue("bookmark") == JsonNull) null else j.getValue("bookmark").jsonObject.let { Bookmark(it.owner("owner"), it.long("positionMs").also { require(it >= 0) }) },
            j.maybeText("traversal")?.let(UUID::fromString), j.long("sequence").also { require(it >= 0) }, j.boolean("completed")) },
    )
    require(state.grants.distinctBy { it.id }.size == state.grants.size)
    require(state.files.distinctBy { it.id }.size == state.files.size && state.files.distinctBy { it.objectId }.size == state.files.size)
    require(state.servers.distinctBy { it.owner.key }.size == state.servers.size)
    require(state.journal.distinctBy { it.key }.size == state.journal.size)
    val grants = state.grants.associateBy { it.id }
    state.files.forEach { f ->
        require(f.aliases.distinctBy { it.grantId to it.locator }.size == f.aliases.size)
        require(f.aliases.all { it.grantId in grants && (it.state != AccessState.AVAILABLE || grants.getValue(it.grantId).state == AccessState.AVAILABLE) })
    }
    val aliasOwners = state.files.flatMap { f -> f.aliases.filter { it.state == AccessState.AVAILABLE }.map { it.locator to f.id } }.groupBy { it.first }
    require(aliasOwners.values.all { it.map { p -> p.second }.distinct().size == 1 })
    state.journal.forEach { j ->
        require(j.bookmark == null || j.bookmark.owner.key == j.key)
        require(!j.completed || (j.bookmark == null && j.traversal != null))
        require(j.traversal != null || j.sequence == 0L)
        require(when (val k = j.key) { is HistoryKey.Device -> state.files.any { it.id == k.id }; is HistoryKey.Server -> j.bookmark == null || state.servers.any { it.owner.key == k } })
    }
    // Unknown/partial fields and malformed primitive types are rejected, not silently dropped on save.
    require(encodeDomain(state) == root)
    // Format 1 is canonical writer JSON, not an interchange document. This also refuses duplicate
    // keys hidden by the JSON tree parser and invalid UTF-8 replacement decoding, preserving bytes.
    require(encodeDomain(state).toString().toByteArray(Charsets.UTF_8).contentEquals(bytes))
    return state
}
