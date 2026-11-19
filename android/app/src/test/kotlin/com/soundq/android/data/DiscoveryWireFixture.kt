package com.soundq.android.data

import com.soundq.android.data.discovery.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import mockwebserver3.MockResponse
import mockwebserver3.QueueDispatcher
import mockwebserver3.RecordedRequest
import java.util.concurrent.TimeUnit.SECONDS

internal fun DiscoveryRepository.searchBlocking(view: DiscoveryView, draft: DiscoveryDraft) = runBlocking { search(view, draft) }
internal fun DiscoveryRepository.searchBlocking(request: DiscoverySearchRequest) = runBlocking { search(request) }

/** Both queued replies start from the same fixture corpus; route by requested provider, not arrival order. */
internal class DiscoveryFixtureQueue : QueueDispatcher() {
    override fun dispatch(request: RecordedRequest): MockResponse {
        val response = super.dispatch(request)
        if (response.headers["X-Fixture-Split"] != "yes") return response
        val provider = checkNotNull(request.url.queryParameter("providers"))
        check(request.url.encodedPath == "/api/v1/discovery/search" && provider in setOf("youtube", "soundcloud"))
        val body = if (response.code == 200) singletonSongBody(okio.Buffer().also { response.body!!.writeTo(it) }.readUtf8(), provider) else "{}"
        return MockResponse.Builder().code(response.code).body(body).build()
    }
}

internal fun HttpsFixture.replySong(body: String, code: Int = 200) {
    check(server.dispatcher is DiscoveryFixtureQueue)
    repeat(2) { server.enqueue(MockResponse.Builder().code(code).addHeader("X-Fixture-Split", "yes").body(body).build()) }
}

internal fun singletonSongBody(body: String, provider: String): String {
    val base = Json.parseToJsonElement(body).jsonObject
    val rows = base.getValue("results").jsonArray
    val selected = rows.filter { it.jsonObject["provider"]?.jsonPrimitive?.content == provider }
    val status = base.getValue("providers").jsonArray.singleOrNull { it.jsonObject["provider"]?.jsonPrimitive?.content == provider }
        ?: buildJsonObject { put("provider", provider); put("status", "ok"); put("resultCount", 0) }
    return buildJsonObject {
        put("query", base.getValue("query"))
        put("results", JsonArray(selected))
        put("providers", JsonArray(listOf(status)))
        put("selectionRequired", selected.isNotEmpty())
        if (selected.isNotEmpty()) {
            val id = base.getValue("selectionSessionId").jsonPrimitive.content
            put("selectionSessionId", if (provider == "soundcloud" && selected.size != rows.size) "123e4567-e89b-12d3-a456-426614174079" else id)
            put("selectionExpiresAt", base.getValue("selectionExpiresAt"))
        }
    }.toString()
}

internal fun HttpsFixture.takeSongRequests(): List<RecordedRequest> = List(2) { checkNotNull(server.takeRequest(3, SECONDS)) }.also { requests ->
    check(requests.map { it.url.queryParameter("providers") }.toSet() == setOf("youtube", "soundcloud"))
}
