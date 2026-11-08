# Android system-media slice

The existing MediaLibraryService remains the only player/session/transport. Media3 is pinned at 1.11.1. Source contracts were fetched from Google's source JARs before implementation.

## Implemented

- Exported media service and Auto media descriptor. Connections require own UID or Media3 OS-trusted control plus verified package/UID identity. On API <33 legacy callbacks use PackageManager UID membership because Media3 does not set its verification flag there. There is no package-name allowlist, untrusted read access or blanket UID grant.
- Authenticated Library and On this device folders; stable `library:<track>` / `device:<track>` IDs, bounded paging (1–100 rows, offset <=100000), search/results, subscription admission, metadata and artwork. Browse runs off-main via the existing API. A bounded 500-entry scope-owned admission cache prevents arbitrary controller IDs becoming audio grants. External URL/mediaUri requests are refused. Every playback item is resolved through the existing occurrence/grant path. Device items keep localOnly and omit remote artwork.
- Voice request metadata resolves an authenticated search through onSetMediaItems. Held search/resumption is fenced by account and transport generation, including interruption cancellation. Browse/prepare never calls play. Media3 owns explicit play. Queue startup restores paused; metadata-only resumption never starts playback.
- AudioManager focus with pause-on-duck, transient resume token, explicit command cancellation, noisy and removed private-output pause. No telephony permission or second player. Calls are represented by OS audio focus loss. No automatic resume after noisy/route/permanent loss. Notification transport/metadata are Media3 defaults, with immutable session Activity intent and existing scoped artwork loader.
- Bounded reconnect attempts (1/2/4/8/16 seconds) rebuild a fresh connection without replaying old commands. Existing terminal connection guards remain. Queue metadata list is reused on progress-only projection ticks; queue visuals are remembered by list/current identity.
- Service-owned playback history producer. It matches the executed Flutter raw position >=30000ms OR natural completion rule, with track-ID dedup across same-track occurrences and reset on null/account retirement. Auto-transition completion uses the old canonical occurrence/track. POST `/me/plays` is off-main, remoteCurrent-only, exact201 and typed `{trackId,played:true}`. No context is invented where native queue lacks context provenance. Unlike Flutter, uncertain/failed writes are NOT blindly retried. There is no server idempotency key. Device-only and explicit localOnly playback do not post.

## Current-song Like

The service projects an account/track acknowledgement from the existing LibraryRepository. Media3 heart buttons use an opaque captured action in `customAction`, not extras (pinned Media3 ignores extras for command equality and legacy commands). Trusted admitted system controllers and own UID can invoke only that captured Like command; mix/Jam/Undo remain own-UID-only.

The repository shares one receipt/pending lock between Library rows and notification actions. No optimistic heart, playback command, selection epoch increment or queue replacement occurs. Next and same-ID replacement refuse a retained pre-admission offer; an entered write settles its original account/track independently. Query refinement preserves its own filter and metadata while accepting shared heart readback. Unknown/off-page current tracks are read through the existing owned Library page contract without changing that filter. Device-only, localOnly, mixed, retired and locked items cannot write. Disk-restored metadata is not liked acknowledgement.

Uncertain writes send once and keep a distinct outcome. The offered “Reload Like status” action performs GET-only reconciliation; only a fresh acknowledged action can toggle afterward. Readback failure is distinct from refusal and uncertainty. `NotificationLikeJourneyTest` compiles the actual MediaSession/controller Like/Unlike path. Host callback extraction executes actual service bodies, LibraryRepository, SoundQApi and trusted synthetic TLS, not OS notification paint or tap behavior.

## Bounded instrumentation

MainActivity exposes debug/test opt-in start/end, records actual Window FrameMetrics plus native touch dispatch. Maximum 600 frame and 600 input samples, maximum60s, stops when Activity stops. No per-frame disk writes. Output is private `filesDir/interaction-queue.json` in the supplied populated ordinary-root journey.

Frame columns: totalNs, inputHandlingNs, layoutMeasureNs, drawNs, deadlineNs, droppedCallbacks. Android FrameMetrics values are nanoseconds. Deadline is -1 before API31. droppedCallbacks is a count, not frame time. Input columns: dispatchNs and eventAgeNs. Event age converts uptime milliseconds to nanoseconds; dispatch uses elapsedRealtimeNanos. Neither is input-to-photon latency, FPS, acoustic timing or audio CPU. Overflow counts remain in the report. This is diagnostic instrumentation, not a calibrated performance gate.

`InteractionPerformanceJourneyTest` compiles a 120-occurrence actual service queue, routed native queue scroll and audio controls. It is not executed in this lane. Waveform/nativeMix files remain independent. Later integration can call the same Activity collector for the real waveform flow; no moving waveform interface is assumed. W6 design ZIP/reference is design evidence only, not Android smoothness.

## Remaining qualification

Parent owns actual OS/Auto/Assistant host, foreground focus permission behavior on Android15+, lockscreen/media buttons, phone calls, Bluetooth/USB disconnects, service process death/reconnect and reboot resumption, notification artwork/actions, real queue gesture acceptance, and quiet matched performance/audio/physical measurements. No emulator/ADB/install occurred. Reboot MediaButtonReceiver is not added. Current-song Like is source/host qualified; OS notification paint/tap remains unaccepted. No background UI frame-clock/waveform rewrite is claimed. Historical playlist position failure and its assertions remain untouched.
