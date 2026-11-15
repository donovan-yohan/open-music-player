# Weekly discovery API (`weekly-v1`)

All routes are additive, authenticated current-account routes under
`/api/v1/me/discovery`. They use the normal server router, auth service and Go
startup schema. Private responses, including auth refusals on these routes, are
`Cache-Control: private, no-store`. No client-supplied account ID is accepted.

| Method | Path | Body / response |
|---|---|---|
| GET | `/weekly` | `WeeklyPage` |
| GET | `/preferences` | `PreferencesPage` |
| GET | `/feedback/{recordingMbid}` | `Feedback` |
| PUT | `/feedback/{recordingMbid}` | `FeedbackWrite` / `FeedbackAck` |
| PUT | `/preferences` | `PreferenceWrite` / `PreferenceAck` |
| POST | `/preferences/reset` | `ResetWrite` / `ResetAck` |
| GET | `/preferences/export` | bounded `Export` |

See `weekly-v1/schema.json` for Go-produced DTO schemas and `weekly-v1/` for
actual synthetic authenticated-route examples. These are not personal or live
provider results. UUIDs must be canonical lowercase, non-nil UUID strings.
Timestamps use RFC3339 UTC. `batchId` is explicitly nullable, but the field is
required in a feedback write. Other required fields may not be null. Duplicate
or unknown JSON fields (including case variants of the exact DTO field names),
ambiguous permission/artist variants, account fields,
and unsupported query parameters are refused. JSON requests are at most 8 KiB.

## Weekly result and ranking

The UTC week begins Monday at 00:00. The first eligible visit lazily admits one
durable attempt for that account/week. An attempt is independent of the profile
epoch. Reset, permission transitions, process restart and public cache loss do
not replenish it. Failure or retired publication waits until the later of the
next Monday and attempt time plus 24 hours. An admitted pending attempt has a
15-second lease and a unique token. Publication checks the token, lease, epoch
and permission generation after provider work, outside the database lock.

The frozen result contains at most 20 original positions and retains the current
and previous accepted generation. Visits do not rerank or refill it. Current
ownership, factual non-skip recent recordings over 30 days, exact recording
downvotes and any credited blocked artist remove rows in original order. Clear
or unblock can restore an eligible original position. A failed new attempt is
not served as an old warm successful batch. Business statuses are `ready`,
`partial`, `empty`, `needs_preferences`, `consent_required`, `pending`,
`unavailable` and `stale`. A missing batch or time is never fabricated.

External MusicBrainz recording metadata is not a playable source, media URL or
Library track ID. The original source/inspect/import/playback owners are
unchanged. A Find sources consumer must re-read the current weekly result and
revalidate the exact original row before using existing source inspection.

The deterministic `signed-artists-v1` policy scores the primary artist using
explicit interest (+1), current signed recording-vote affinity (per artist
clamped to [-3,3]), and only permissioned server history (+0.5 for a 30-day artist
or +0.25 for a 90-day-only artist). It never uses MusicBrainz search relevance as
taste similarity. Missing audio features are unavailable and unscored. ID ties
are deterministic. At most two rows use one primary artist; adjacent repetition
is avoided when another eligible artist remains. Components and reasons describe
the actual frozen generation, not a later preference recomputation.

Candidate work has at most five seed artists, two logical MusicBrainz recording
pages, 200 raw candidates, four actual HTTP dispatches including retries and
redirects, 1 MiB per decoded provider page, 2 MiB cumulative response bytes read,
and a 15-second generation deadline. The existing shared per-origin/application
process-local pacing remains fixed at one second after returned headers. It is
not distributed coordination. Weekly flights are budget-isolated from ordinary
search and radar flights. Cross-origin weekly redirects are refused. Coverage
counts actual logical page attempts, transport requests and bytes read; cached
metadata is not counted as a new provider request. Existing radar date/admission
policy is unchanged.

## Permissions and choices

All new permissions default false. `learningFromServerHistory` only admits
existing non-skip server events through generation time. No local-history upload,
new telemetry, Library-like learning or playlist learning is added. Short and
long history coverage remain separate. External catalog permission is independent
of history permission. Similar-artist expansion is unavailable in this initial
weekly policy (`similarArtistAvailable:false`), even if its separate permission
is stored. Existing operator-gated ListenBrainz endpoints and algorithm are not
changed or activated.

Artist choices require canonical account-owned verified Library evidence or
accepted weekly/current-feedback artist evidence. Caller-provided names and
hidden unconsented identity searches are not accepted. A block wins over an
interest without erasing that interest. `PreferenceAck` always emits `permission`
and `artist`, exactly one non-null. Neutral retained artist resources are exposed
in `interestedArtists` with both flags false so their revision remains readable;
consumers must use the explicit flags. An interested and blocked choice appears
in both lists.

Preferences use default/max `limit=50`, with separate `feedbackCursor` and
`artistCursor` continuations. A continuation must include the returned global
`preferenceRevision`; a changed revision refuses instead of mixing snapshots.
Current non-neutral feedback is paginated. Exact neutral feedback tombstones
remain readable by the feedback route. Derived affinity summaries are artist-ID-
ordered prefixes capped at 50 entries, shortened further after assembling the
complete canonical page to keep its actual escaped JSON within 1,800,000 bytes.
Canonical feedback, choices, cursors and revisions are not shortened. These
summaries are not exhaustive raw listening history and do not limit internal
ranking or seed affinities.

## Reversible feedback and uncertain writes

There is one current vote per account/canonical recording, not one contribution
per tap. `up`, `down` and `none` replace that resource under its own
`expectedRevision`. Clear retains its neutral revision tombstone. New resources
require that account's accepted weekly provenance. Existing feedback can be
corrected after batch expiry using `batchId:null`; a foreign batch never grants
authority. Up and soft preferences affect future generations only. Exact down
also filters the current original result. It does not block the artist or edit
Library favorites, membership, playlists or playback queues.

Under one account-row transaction, mutation ID plus semantic payload is compared
before revision refusal. Exact retained replay acknowledges the original result
with `replayed:true`; ID/payload mismatch conflicts. The last 128 accepted
operation payload/ack pairs are retained. Older pruned requests still fail their
old resource revision/epoch. Replay is not permanent deduplication or an unbounded
tap ledger. Resource limits are 2,000 feedback/tombstones, 1,000 artist choices
and below 1.8 MB encoded private state (2 MiB database constraint). The byte bound
can refuse before the row bound.

After response loss, read exact feedback and reconcile `lastMutationId`, revision
and epoch. Retry only the same immutable operation within its captured scope.
Never automatically rebase an old request onto a new revision. HTTP 400 denotes
invalid input, 401 missing/invalid auth, 404 unknown/foreign provenance or absent
canonical artist evidence. Revision/epoch/payload conflicts are HTTP 409 with
`code`, `detail`, authoritative `current` where safe, and current account revision
metadata. Other errors retain the repository's flat `{code,message}` shape.
Storage/transport faults are not successful empty preference responses.

Reset scope is exactly `discovery_preferences`. It atomically clears discovery
choices, feedback and private batches, advances the epoch, turns history learning
off and retires old writers/publishers. Provider permissions and consumed attempt
entitlements survive. It does not clear factual plays, favorites, Library,
playlists, downloads or files. Export includes canonical choices/current feedback
and neutral tombstones, permissions and bounded derived affinities, without raw
history, replay records, provider attempt internals or credentials. The derived
export summary is an artist-ID-ordered prefix of at most 50 entries (the same
count policy as Preferences), shortened further when necessary to keep the
actual JSON response within 1,800,000 bytes after escaping. Every canonical
choice and current feedback resource is included unchanged; `truncated:false`
refers to those canonical resources, not an exhaustive derived affinity list.
`historyIncluded:false` remains explicit. This does not bound the affinities
used internally for ranking or seed selection. When retained primary-artist
labels disagree, the derived display label is the lexicographically smallest
evidenced label, independent of map iteration; canonical metadata is unchanged.

## Qualification limits

The synthetic evaluation is a deterministic regression cohort, not a tuned
recommender or a claim of personal usefulness, audible availability or production
novelty. Production provider activation and personal reset/history rehearsal are
not part of this implementation. Android parsing, native interaction, independent
review, merge/publication and rollout require their own exact-artifact evidence.
