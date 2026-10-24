# ADR 0013: Embedded native client application core

Status: Experimental, not a Flutter replacement

## Intent and source

Build the smallest real native tracer: authenticated paged library, selection,
cold and cached original playback, pause/resume/seek/retry and native session
controls on macOS and Android. The Go backend remains the only server/schema
and token-issuance authority. Windows is an architecture target, not a supported
output target. Flutter remains intact until the complete parity ledger and
platform gates pass.

Baseline: 3069002f4d9ae83e15235ce876bf20e17e92d12d. The external frozen reference
manifest covers 819 files from desktop candidate 7f38642 plus a recorded dirty
overlay. The mission evidence directory contains source-backed content/audio
inventories and explicit unread areas; these are not runtime acceptance.

## Decision and boundaries

Choose proposal A's in-process Rust application core over a localhost daemon.
Use proposal B's immutable messages at the native audio boundary, but keep
HTTP/auth/paging/cache policy shared in Rust rather than duplicate executors.
Native Swift/AppKit and Kotlin/Android views own layout, focus, accessibility,
gestures and animation. Each process/service owns one core and one ordinary
platform decoder, with no competing platform queue. Native OS controls dispatch
the same core commands as visible controls.

The initial C ABI has opaque handles, ABI version negotiation, bounded UTF-8 JSON
commands/results and same-library explicit buffer free. No borrowed result
pointer escapes a call. No callback crosses the ABI, much less per audio sample.
Swift imports a C module; Android uses a thin JNI string/handle bridge. Windows
P/Invoke can use the same fixed-width cdecl ABI and owned UTF-8 buffers; C# UniFFI
support is not assumed. Windows output, MSVC binaries and runtime remain untested.

Core commands execute on a non-UI serial worker. A separate atomic revoke lane
invalidates intent synchronously, even while a request is blocked in HTTP. Every
request captures the current epoch, every publication checks it, and audio
completions must match account and session incarnations. Revocation does not
claim that physical output is stopped: the native adapter pauses/closes its sole
decoder before admitting successor audio, and then acknowledges the new scope.
A command receipt is not physical audio evidence. No automatic uncertain-write
replay is allowed.

Credentials stay in platform secure storage and private core/adapter messages,
never published snapshots or logs. API origins are explicit (OMP_API_BASE_URL
remains supported). Cache paths are endpoint/account scoped; signed URLs are
transport-only, not identities. Original audio uses platform decoding, not the
prepared Opus decoder. Existing client/native C/C++ DSP is retained at its current
path until actual prepared playback consumers are rewired; its existence is not
native-port acceptance.

## Actual server contracts

- POST /api/v1/auth/login {email,password}, 200
  {accessToken,refreshToken,expiresIn,user:{id,email,username,...}}.
- POST /api/v1/auth/register {email,password,username}, 201, same response.
- POST /api/v1/auth/refresh {refreshToken}, 200, rotated token pair.
- POST /api/v1/auth/logout authenticated, no mutation replay.
- GET /api/v1/library?limit=50&offset=0&sort=added_at&order=desc&q=...
  {tracks:[{id,title,artist?,album?,duration_ms?,...}],total,limit,offset}.
  Empty tracks is []; JSON null from older servers is tolerated as empty.
- POST /api/v1/playback/urls {trackIds:[int64],ttlSeconds:600}
  {urls:[{trackId,url,expiresAt,contentType,sizeBytes,etag?,storageKeyVersion?,...}],
   unavailable?:[{trackId,code,message}]}.

Sources: backend/internal/auth/{handlers,auth}.go,
backend/internal/api/{library,playback,router}.go. Import /queue jobs are distinct
from listening occurrences. A repeated recording receives a new occurrence ID.

## Compatibility and exclusions

Development apps use distinct package/Keychain/data namespaces. They never
uninstall the current app, clear its data or import/delete its credentials or
files. Coexistence is an explicit non-destructive preview compatibility path,
not completed migration of existing sessions/offline data. A tested production
migration remains a cutover gate.

First-slice excluded until separately implemented and qualified: prepared mixes,
DJ/stems, collaboration, all-format/offline parity, biometric lock, full
playlist/search/import flows and Flutter removal. No enabled placeholder control
may stand in for these capabilities.

## Backpressure and acceptance

Rust tests must reject stale completions/cancelled requests, malformed boundary
input, invalid paging and cross-account cache reuse. C/Swift/JNI smoke tests must
exercise real allocation/free and the versioned ABI. Native compilation, clean
tracked-snapshot reproducibility, real backend fixture conformance, cold/warm
physical output, native session actions and source-bound performance traces are
separate gates. Failed gates remain in the evidence home. Full migration and
Flutter removal require the user's complete mission predicate, not this tracer.
