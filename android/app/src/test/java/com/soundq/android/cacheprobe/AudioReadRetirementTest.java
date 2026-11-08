package com.soundq.android.cacheprobe;

import com.soundq.android.data.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import okhttp3.*;
import okio.Buffer;
import okio.BufferedSource;
import okio.ForwardingSource;
import okio.Okio;
import org.junit.Test;
import static org.junit.Assert.*;

/** Real TLS bytes; only the body-read scheduling boundary is held. */
public final class AudioReadRetirementTest {
    @Test public void grantReplacementDuringReadCannotReturnBytesOrPublishCache() throws Exception { verify(false); }
    @Test public void accountRetirementDuringReadCannotReturnBytesOrPublishCache() throws Exception { verify(true); }
    @Test public void currentReadPublishesReusableExactCacheBytes() throws Exception { verify(null); }

    private MediaGrant grant(AccountScope scope) throws Exception {
        return MediaGrant.class.getConstructor(AccountScope.class, long.class, boolean.class, kotlin.jvm.internal.DefaultConstructorMarker.class).newInstance(scope, 7L, false, null);
    }
    private void verify(Boolean retireAccount) throws Exception {
        Path directory = Files.createTempDirectory(Path.of(System.getenv("TMPDIR")), "audio-read-retirement-").toRealPath();
        var entered = new CountDownLatch(1);
        var release = new CountDownLatch(1);
        var armed = new AtomicBoolean(false);
        var executor = Executors.newSingleThreadExecutor();
        SignedAudioDataSource source = null;
        try (var fixture = new HttpsFixture()) {
            var session = new AccountSession(fixture.getEndpoint(), new MemoryStore());
            assertTrue(session.accept(session.beginIntent(), new SecretTokens("fixture-access", "fixture-refresh", "fixture")));
            var scope = Objects.requireNonNull(session.capture());
            var media = fixture.getClient().newBuilder().addNetworkInterceptor(chain -> {
                var response = chain.proceed(chain.request());
                if (!chain.request().url().encodedPath().equals("/media/retirement.wav")) return response;
                var original = response.body();
                var held = Okio.buffer(new ForwardingSource(original.source()) {
                    @Override public long read(Buffer sink, long byteCount) throws java.io.IOException {
                        if (armed.getAndSet(false)) {
                            entered.countDown();
                            try { if (!release.await(5, TimeUnit.SECONDS)) throw new java.io.IOException("Fixture read gate expired"); }
                            catch (InterruptedException failure) { Thread.currentThread().interrupt(); throw new java.io.IOException("Fixture interrupted"); }
                        }
                        return super.read(sink, byteCount);
                    }
                });
                return response.newBuilder().body(new ResponseBody() {
                    @Override public MediaType contentType() { return original.contentType(); }
                    @Override public long contentLength() { return original.contentLength(); }
                    @Override public BufferedSource source() { return held; }
                }).build();
            }).build();
            var graph = new CacheGraph(directory.toFile(), session, media);
            var grants = new ConcurrentHashMap<String, MediaGrant>();
            var uri = Uri.Companion.parse("soundq://track/7/retirement");
            grants.put(uri.toString(), grant(scope));
            byte[] bytes = new byte[1024]; Arrays.fill(bytes, (byte) 37);
            fixture.reply("{\"urls\":[{\"trackId\":7,\"url\":\"" + fixture.getServer().url("/media/retirement.wav") + "\",\"expiresAt\":\"2030-01-01T00:00:00Z\",\"contentType\":\"audio/wav\",\"sizeBytes\":1024}]}", 200);
            fixture.getServer().enqueue(new mockwebserver3.MockResponse.Builder().body(new Buffer().write(bytes)).build());
            source = new SignedAudioDataSource(graph, grants);
            assertEquals(1024L, source.open(new DataSpec(uri, 0, -1, Collections.emptyMap())));
            assertEquals(1, graph.getTemporaryAudio().status().getWritingFiles());
            armed.set(true);
            final var reading = source;
            var result = executor.submit(() -> {
                try { return "bytes:" + reading.read(new byte[1024], 0, 1024); }
                catch (Exception failure) {
                    if (failure instanceof SafeFailure safe) return "refused:" + safe.getReason();
                    throw failure;
                }
            });
            assertTrue("Real body read entered", entered.await(3, TimeUnit.SECONDS));
            if (Boolean.TRUE.equals(retireAccount)) session.retire();
            else if (retireAccount != null) grants.put(uri.toString(), grant(scope));
            release.countDown();
            assertEquals("Only current reads may return late audio", retireAccount == null ? "bytes:1024" : "refused:Retired", result.get(3, TimeUnit.SECONDS));
            source.close(); source = null;
            assertEquals("Only current reads may publish cache", retireAccount == null ? 1 : 0, graph.getTemporaryAudio().status().getFiles());
            assertEquals(0, graph.getTemporaryAudio().status().getWritingFiles());
            assertEquals(2, fixture.getServer().getRequestCount());
            if (retireAccount != null) {
                if (retireAccount) {
                    assertTrue(session.accept(session.beginIntent(), new SecretTokens("fresh-access", "fresh-refresh", "fixture")));
                    scope = Objects.requireNonNull(session.capture());
                }
                grants.put(uri.toString(), grant(scope));
                fixture.reply("{\"urls\":[{\"trackId\":7,\"url\":\"" + fixture.getServer().url("/media/retirement.wav") + "\",\"expiresAt\":\"2030-01-01T00:00:00Z\",\"contentType\":\"audio/wav\",\"sizeBytes\":1024}]}", 200);
                fixture.getServer().enqueue(new mockwebserver3.MockResponse.Builder().body(new Buffer().write(bytes)).build());
                source = new SignedAudioDataSource(graph, grants);
                assertEquals(1024L, source.open(new DataSpec(uri, 0, -1, Collections.emptyMap())));
                byte[] fresh = new byte[1024]; assertEquals(1024, source.read(fresh, 0, 1024)); assertArrayEquals(bytes, fresh);
                source.close(); source = null;
                assertEquals(1, graph.getTemporaryAudio().status().getFiles());
                assertEquals(4, fixture.getServer().getRequestCount());
            }
            int requests = fixture.getServer().getRequestCount();
            source = new SignedAudioDataSource(graph, grants);
            assertEquals(1024L, source.open(new DataSpec(uri, 0, -1, Collections.emptyMap())));
            byte[] cached = new byte[1024]; assertEquals(1024, source.read(cached, 0, 1024)); assertArrayEquals(bytes, cached);
            source.close(); source = null;
            assertEquals(requests, fixture.getServer().getRequestCount());
        } finally {
            release.countDown(); executor.shutdownNow(); assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS));
            if (source != null) source.close();
            try (var paths = Files.walk(directory)) { for (var path : paths.sorted(Comparator.reverseOrder()).toList()) Files.delete(path); }
        }
    }
}
