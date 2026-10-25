#ifndef SOUNDQ_MIX_H
#define SOUNDQ_MIX_H
#include <stdint.h>

#if defined(_WIN32)
# if defined(SQ_BUILD)
#  define SQ_API __declspec(dllexport)
# else
#  define SQ_API __declspec(dllimport)
# endif
#else
# define SQ_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif

#define SQ_ABI_VERSION 1u
#define SQ_MAX_DECKS 4u
#define SQ_MAX_BUSES 5u
#define SQ_QUEUE_CAPACITY 8u

typedef struct sq_engine sq_engine;
typedef enum sq_result {
  SQ_OK = 0, SQ_INVALID = 1, SQ_QUEUE_FULL = 2, SQ_STALE_REVISION = 3,
  SQ_BUSY = 4
} sq_result;

typedef struct sq_config {
  uint32_t abi_version;
  uint32_t sample_rate;
  uint32_t max_block_frames;
  uint64_t max_asset_frames;
} sq_config;

/* Borrowed immutable, interleaved L,R float32 buses, all aligned to one source
 * origin, same sample rate and frame count. No compressed formats/decoders here.
 * Descriptor is copied by submit, sample bytes are NOT copied or owned.
 * Caller retains every bus until the replacing revision is applied AFTER render
 * completes, and no queued/current plan references it. Stop alone is not release.
 * No overlapping output/input buffers. Pointer validity is the caller's duty. */
typedef struct sq_pcm {
  uint32_t sample_rate;
  uint32_t bus_count;
  uint64_t frame_count;
  const float *buses[SQ_MAX_BUSES];
} sq_pcm;

typedef struct sq_bus_control {
  float gain;                 /* finite [0,1], remembered while muted */
  uint32_t muted;             /* exactly 0 or 1 */
  uint32_t ramp_frames;       /* live change: first sample old+(target-old)/N */
} sq_bus_control;

typedef struct sq_deck {
  uint32_t slot;              /* unique 0..3; overlap instances need own slots */
  uint64_t instance_id;       /* nonzero; unchanged identity preserves ramps */
  sq_pcm pcm;
  uint64_t start_frame;       /* absolute shared timeline, inclusive */
  uint64_t end_frame;         /* exclusive stop; source exhaustion is silence */
  uint64_t source_start_frame;
  uint32_t has_seek;          /* exactly 0 or 1, optional exact in-block seek */
  uint64_t seek_frame;        /* inside [start,end) */
  uint64_t seek_source_frame;
  sq_bus_control buses[SQ_MAX_BUSES];
} sq_deck;

typedef struct sq_plan {
  uint64_t revision;          /* strictly increasing on successful submit only */
  uint32_t deck_count;        /* 0..4; full replacement, never truncate a fifth */
  float master_gain;         /* finite [0,1], fixed headroom then hard clip */
  sq_deck decks[SQ_MAX_DECKS];
} sq_plan;

/* Creation/destruction are non-render operations. Destroy only after both owner
 * threads are stopped. Null config or invalid bounds returns NULL. */
SQ_API sq_engine *sq_create(const sq_config *config);
SQ_API void sq_destroy(sq_engine *engine);
/* Exactly one producer. Validates the ENTIRE plan, then nonblocking enqueue.
 * Queue/full/invalid/stale failures change neither accepted plan nor revision.
 * One consumer sq_render, no concurrent render calls. Submit may overlap render.
 * Queue is bounded SPSC with lock-free indices, not a general MPSC FFI API. */
SQ_API sq_result sq_submit(sq_engine *engine, const sq_plan *plan);
/* A render call is the only block boundary. Captures queued plans at entry,
 * applies them in order atomically before any samples, no mid-block updates.
 * Rate is exactly 1.0. Advances ONE timeline cursor by frames even in silence.
 * No allocation, locks, I/O, decoding or user callbacks. frames must be 1..max.
 * Invalid render leaves output, queue, cursor and applied revision unchanged.
 * NaN/Inf source samples become zero per channel; accumulate in double, apply
 * master headroom, then clamp [-1,1]. No limiter, normalization or dithering. */
SQ_API sq_result sq_render(sq_engine *engine, float *stereo_out, uint32_t frames);
/* Cross-thread acquire queries; revision is published after a completed block.
 * These are independent snapshots, NOT an atomic (revision,cursor) pair. */
SQ_API uint64_t sq_applied_revision(const sq_engine *engine);
SQ_API uint64_t sq_rendered_frames(const sq_engine *engine);

/* Additive long-arrangement ABI. ABI-v1 structs and sq_submit are unchanged.
 * Metadata and borrowed residency are separate; NONE of these calls decode PCM.
 * Compile/submit/status/retire use the same single producer as sq_submit. */
#define SQ_SCHEDULE_MAX_CLIPS 16384u
#define SQ_SCHEDULE_MAX_WINDOWS 128u
#define SQ_SCHEDULE_MAX_SPANS 65536u
#define SQ_SCHEDULE_MAX_BOUNDARIES_PER_BLOCK 64u
#define SQ_SCHEDULE_MAX_RESIDENT_FRAMES 1048576u

typedef struct sq_schedule sq_schedule;
typedef struct sq_schedule_clip {
  uint64_t instance_id;       /* globally unique within the full arrangement */
  uint64_t asset_id;          /* nonzero immutable source/channel identity */
  uint64_t start_frame;       /* inclusive absolute native timeline */
  uint64_t end_frame;         /* exclusive; positive duration */
  uint64_t source_start_frame;
  uint64_t source_frame_count;/* full source extent, NOT resident PCM size */
  uint32_t bus_count;         /* 1..5, invariant for the same asset_id */
  sq_bus_control buses[SQ_MAX_BUSES];
} sq_schedule_clip;
typedef struct sq_pcm_window {
  uint64_t asset_id;
  uint64_t source_start_frame;/* source frame represented by pcm frame zero */
  sq_pcm pcm;                /* immutable borrowed bounded decoded bytes */
} sq_pcm_window;
typedef struct sq_schedule_desc {
  uint64_t revision;          /* shared increasing namespace with sq_submit */
  float master_gain;
  uint32_t clip_count;
  const sq_schedule_clip *clips;
  uint32_t window_count;
  const sq_pcm_window *windows;
} sq_schedule_desc;
typedef enum sq_schedule_state {
  SQ_SCHEDULE_READY = 0, SQ_SCHEDULE_IN_USE = 1, SQ_SCHEDULE_COMPLETE = 2
} sq_schedule_state;
/* Allocates, validates FULL arrangement and compiles sorted active-set spans
 * off callback. At most four simultaneous clips (ends precede starts). Rejects
 * >64 distinct span boundaries in ANY max_block_frames half-open interval.
 * Resident windows of an asset must not overlap. Aggregate window frame counts
 * <=1048576 (including repeated buffers); each <= config.max_asset_frames.
 * Descriptor/arrays are copied; PCM is borrowed. On failure *out=NULL.
 * Same asset_id must have consistent full extent and bus count. No looping,
 * seeks, rate changes or implicit replacement of missing windows. */
SQ_API sq_result sq_schedule_create(sq_engine *engine, const sq_schedule_desc *desc,
                                    sq_schedule **out);
/* Single-use handle bound to its creating engine. Nonblocking pointer enqueue
 * through the SAME eight-entry queue as sq_submit. Captured installs apply at
 * block entry; future starts/windows then execute natively at exact frames.
 * Invalid/stale/full failures leave handle READY and accepted state unchanged. */
SQ_API sq_result sq_schedule_submit(sq_engine *engine, sq_schedule *schedule);

/* Additive authored automation, no changes to any ABI-v1 POD size. Values are
 * source-clock anchored (rate 1). Events sorted by (source_frame,bus), unique.
 * At the event frame gain equals the actually reached prior ramp value; target
 * is reached at source_frame+ramp_frames. Before the first event gain is one.
 * Metadata copied/compiled off callback; PCM bytes remain untouched/borrowed. */
#define SQ_AUTOMATION_MAX_EVENTS_PER_CLIP 2048u
#define SQ_AUTOMATION_MAX_EVENTS 4096u
#define SQ_AUTOMATION_MAX_EVENTS_PER_BLOCK 64u
typedef enum sq_fade_curve { SQ_FADE_LINEAR=0, SQ_FADE_EQUAL_POWER=1 } sq_fade_curve;
typedef struct sq_stem_event {
  uint64_t source_frame;
  uint32_t bus;
  uint32_t ramp_frames;
  float gain;
} sq_stem_event;
typedef struct sq_clip_automation {
  uint64_t instance_id;
  float base_gain;            /* finite [0,1], applied once, not per-control */
  uint64_t envelope_source_start_frame;
  uint64_t envelope_frame_count;
  uint64_t fade_in_frames;    /* effective fades; sum <= envelope_frame_count */
  uint64_t fade_out_frames;
  uint32_t fade_curve;        /* sq_fade_curve */
  uint32_t stem_override_mask;/* bus bits: live value replaces authored curve */
  uint32_t event_count;
  const sq_stem_event *events;
} sq_clip_automation;
/* One optional automation record per clip instance. At most 4096 total events,
 * 2048/clip, and 64 event records in any max-block half-open timeline interval.
 * Out-of-selected-window events are retained to evaluate trimmed/seeked starts.
 * Reject invalid metadata without consuming a revision or changing the engine. */
SQ_API sq_result sq_schedule_create_automated(sq_engine *engine,
    const sq_schedule_desc *desc, uint32_t automation_count,
    const sq_clip_automation *automation, sq_schedule **out);
SQ_API sq_schedule_state sq_schedule_get_state(const sq_schedule *schedule);
/* Deletes outside callback only. BUSY while queued/current, including after its
 * final clip ends. Replacing completed block marks old handles COMPLETE; engine
 * destruction (threads stopped) does likewise. A skipped queued install is not
 * COMPLETE until its consuming block finishes. Retire READY/COMPLETE succeeds.
 * Borrowed PCM can be freed only after EVERY referencing handle/legacy plan has
 * completed replacement; handle completion alone does not count shared leases. */
SQ_API sq_result sq_schedule_retire(sq_schedule *schedule);
/* Cross-thread independent snapshots, published after a completed block. Missing
 * window => only that clip silent; healthy clips and clock continue. Cumulative
 * missing clip-frames saturates at UINT64_MAX; last ID is sticky, zero initially.
 * Source NaN/Inf still follows the legacy per-sample silence policy. */
SQ_API uint64_t sq_missing_pcm_frames(const sq_engine *engine);
SQ_API uint64_t sq_last_missing_instance(const sq_engine *engine);

#ifdef __cplusplus
}
#endif
#endif
