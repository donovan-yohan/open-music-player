/// Every user-facing string the DJ deck's entry contract introduces or changes
/// (#414).
///
/// The deck used to explain nothing: a refused seed painted an empty lane, an
/// unloaded deck painted a full metric run over silence, and the sync glyph
/// carried internal roadmap language. Holding the copy in one file makes the
/// contract testable — see `test/features/dj/dj_deck_copy_test.dart`, which
/// pins sentence case, forbids exclamation marks and forbids internal jargon
/// over [djDeckCopyStrings].
library;

/// The deck refused a library track because it is not on this device.
const String djDeckDownloadRequired =
    'Download this track to use it on the deck';

/// The picker fallback was handed something that is not a local file.
const String djDeckPickLocalFile =
    'Pick a file on this device to use it on the deck';

/// Resolution or the voice load failed outright; there is nothing to offer.
const String djDeckSourceUnavailable =
    'This track cannot be loaded on the deck right now';

/// The queue holds nothing, so there is nothing for the deck to take.
const String djDeckEmpty =
    'Add a track to the queue, or load a file from this device';

/// The queue is not empty but this deck was never seeded from it. Telling the
/// user to add a track they have already added is worse than saying nothing:
/// only deck A is seeded from a single-row queue, so deck B reaches this state
/// on the ordinary path.
const String djDeckNotSeeded = 'Nothing is loaded on this deck';

/// Deck-lane action that sends the refused track through the app's one
/// download pipeline.
const String djDeckDownloadAction = 'Download';

/// The same action while its transfer is in flight.
const String djDeckDownloadRunningAction = 'Downloading';

/// The same action after a failed transfer.
const String djDeckDownloadRetryAction = 'Retry';

/// Second lane line shown beside [djDeckDownloadRetryAction].
const String djDeckDownloadFailed = 'Download failed. Try again.';

/// Deck-lane action that opens the local-file prompt.
const String djDeckLoadFileAction = 'Load a file';

/// Header status for a deck that holds no audio, in place of the placeholder
/// metric run (`-- BPM`, `+0.0%`, `0:00/-0:00`).
const String djDeckHeaderNotLoaded = 'Not loaded';

/// Tooltip on the transport controls of a deck that holds no audio.
const String djDeckTransportDisabledReason = 'This deck has no track loaded';

/// Idle, enabled SYNC: what one tap will do.
const String djDeckSyncFollowAction = 'Match this deck to the other deck';

/// This deck is an engaged follower.
const String djDeckSyncEngaged = 'Matched to the other deck';

/// This deck is the master. Tapping it hands the master role to the other deck.
const String djDeckSyncMaster = 'This deck sets the tempo';

/// Either deck's BPM is missing or below the reliability floor.
const String djDeckSyncNoTempo = 'This track has no reliable tempo to sync to';

/// The would-be leader deck holds no audio.
const String djDeckSyncOtherDeckUnavailable =
    'Load a track on the other deck to sync';

/// Even octave-normalized, the follower rate falls outside the deck window.
const String djDeckSyncTempoOutOfRange =
    'The tempo gap is too wide for this deck';

/// The deck is landscape only, and Android does not always honour the request
/// immediately (or at all, in split-screen / freeform windows).
const String djDeckRotatePrompt = 'Rotate your phone to use the deck';

/// Detail line under [djDeckRotatePrompt].
const String djDeckRotateDetail = 'The deck is landscape only.';

/// The window is below the minimum serviceable deck box.
const String djDeckTooSmall = 'Not enough room for the deck';

/// Detail line under [djDeckTooSmall].
const String djDeckTooSmallDetail =
    'Try a smaller display size or a larger window.';

/// The one line the player's DJ action adds when the deck may not be able to
/// use what is currently playing.
///
/// Hedged deliberately. The deck accepts local *and* playback-cache-backed
/// sources, but the only synchronous device-side fact the player can consult is
/// `DownloadState.downloadedTrackIds`: `PlaybackCacheManager.get` is async and
/// needs a `SignedAudioDescriptor`, and the cache store exposes no cached-id
/// set. A flat "download this track" therefore lies about a streamed-but-cached
/// row, which loads on the deck today. Follow-up, recorded in
/// docs/dj-deck-spec.md section 1: give the cache a synchronous cached-id
/// projection and make this predicate exact.
const String djDeckEntryDownloadHint =
    'This track may need downloading to load on a deck';

/// Appended to the settings toggle subtitle so the requirement is advertised
/// before the user ever reaches the deck.
const String djDeckSettingsRequirement =
    'The deck plays tracks stored on this device, in landscape only.';

/// The copy contract, in one list, for `dj_deck_copy_test.dart`.
///
/// Deliberate exemptions, which are **not** members of this list: the
/// performance-control glyph labels `CUE`, `CUES`, `LOOP` and `STEMS`, and the
/// `A` / `B` deck letters. Those are DJ-convention labels rather than prose,
/// and #414's acceptance criterion 5 asks for exactly this record. See
/// `docs/dj-deck-spec.md`, "Deck entry contract".
const List<String> djDeckCopyStrings = <String>[
  djDeckDownloadRequired,
  djDeckPickLocalFile,
  djDeckSourceUnavailable,
  djDeckEmpty,
  djDeckNotSeeded,
  djDeckDownloadAction,
  djDeckDownloadRunningAction,
  djDeckDownloadRetryAction,
  djDeckDownloadFailed,
  djDeckLoadFileAction,
  djDeckHeaderNotLoaded,
  djDeckTransportDisabledReason,
  djDeckSyncFollowAction,
  djDeckSyncEngaged,
  djDeckSyncMaster,
  djDeckSyncNoTempo,
  djDeckSyncOtherDeckUnavailable,
  djDeckSyncTempoOutOfRange,
  djDeckRotatePrompt,
  djDeckRotateDetail,
  djDeckTooSmall,
  djDeckTooSmallDetail,
  djDeckEntryDownloadHint,
  djDeckSettingsRequirement,
];
