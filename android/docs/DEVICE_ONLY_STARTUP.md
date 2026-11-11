# Device-only startup and explicit device listening

## Authority

`Use device downloads` reads the same AES-GCM endpoint-bound session record already accepted by online authentication. It publishes `DeviceOnly(accountId)`, never `SignedIn`, and retains no bearer/refresh tokens in that state. The encrypted wire format is unchanged; JWTs are not decoded. Startup still attempts the existing online restore independently. The explicit action claims a new epoch before disk work, so it need not wait for an unavailable network response. Any old refresh result is ineligible to publish or persist afterward.

`AccountScope` is local identity, not remote approval. `remoteCurrent`/`checkRemote` additionally require current online credentials. SoundQApi checks this predicate in the actual network dispatch guard; refresh and device-transfer admission do likewise. Artwork dispatch also requires online permission. Sign-out revokes both capabilities synchronously before deferred cleanup. Rejected session bytes are preserved, and consumed-refresh secure-save failures cannot be bypassed with device entry.

## Listening

The device-only surface exposes Downloads, local removal, existing Media3 transport/queue and Sign out. It does not mount Library, Discover, Home, imports or playlists and does not automatically fetch Library. Missing/invalid local artifacts refuse locally.

Ordinary signed-in **Play device copy** also carries `localOnly` from its actual action through ControllerProjection request metadata, service occurrence metadata and MediaGrant into SignedAudioDataSource. It strips remote artwork and cannot request a descriptor on local-custody loss. Queue persistence and Undo preserve this per-occurrence restriction. Ordinary Library listening remains local-first with remote fallback. The restriction is per requested occurrence, not a global offline toggle; independently queued generic streaming occurrences retain their original intent.

The player remains SoundQLibraryService's single ExoPlayer. Queue reconstruction remains paused and never prepares/autoplays. Downloads errors are readable on the destination. Device-only sign-out returns to sign-in; ordinary online sign-in/restore is unchanged.

## Verification boundaries

- Host tests use trusted real TLS, the actual encrypted session file and device store. Reconstructing those owners against the same durable root proves exact-byte local reads without network. It is not process death.
- `DeviceOnlyStartupJourneyTest` compiles a reconstructed encrypted graph through mounted MainActivity and the actual service/source, with all fixture HTTP refused, bounded local reads, missing-local/artwork refusal, explicit playback and sign-out. Its graph replacement + Activity recreation is a component reconstruction fixture, not ordinary cold-start/process-restart acceptance.
- `DeviceCopyIntentJourneyTest` compiles ordinary signed-in mounted Downloads with remote artwork, then corrupts the artifact after positive Complete presentation and exercises the real action/controller/service/source. It asserts local refusal, readable error and no requests, plus valid-local and generic-Library streaming positives.
- `DeviceFileIdentityTest` compiles the actual Android private-filesystem no-follow fileKey/rename/replacement oracle required by the separately reviewed OFF-1 cleanup repair.
- Native execution, decoder progress, audible output, real AndroidKeyStore and normal-process restart require the parent's separately admitted disposable runtime. No installation or runtime was performed by this source writer.

This closes a native offline-startup gap; active Flutter startup also requires network refresh. It is not a claim of previously working Flutter startup parity or full product parity.
