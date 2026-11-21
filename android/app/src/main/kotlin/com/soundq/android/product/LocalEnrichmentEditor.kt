package com.soundq.android.product

import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.soundq.android.AppGraph
import com.soundq.android.data.AccountScope
import com.soundq.android.data.SafeFailure
import com.soundq.android.data.device.*
import com.soundq.android.data.deviceaudio.DeviceAudio
import com.soundq.android.data.deviceaudio.LocalAppliedCover
import com.soundq.android.data.deviceaudio.LocalDisplayText
import com.soundq.android.data.deviceaudio.MetadataApplyResult
import com.soundq.android.data.discovery.CaaArtworkRef
import com.soundq.android.data.discovery.DiscoveryCalls
import com.soundq.android.product.artwork.ArtworkPaint
import com.soundq.android.product.artwork.PhoneArtwork
import com.soundq.android.product.discovery.RadarArtworkPool
import com.soundq.designsystem.*
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Unique sheet visit; retirement closes even a call registered after cancellation. */
internal class LocalEnrichmentVisit(val account: AccountScope, val row: DeviceAudio) {
    val gate = EnrichmentVisitGate()
    private val coverOwner = AtomicReference<Any?>(null)
    private var artwork: RadarArtworkPool.Lease? = null // window/main callbacks only
    val calls = DiscoveryCalls()
    fun active() = gate.active()
    fun retireArtwork() { coverOwner.set(null); artwork?.close(); artwork = null }
    fun startArtwork(graph: AppGraph, offer: CaaArtworkRef, valid: () -> Boolean): RadarArtworkPool.Lease {
        retireArtwork()
        val owner = Any()
        coverOwner.set(owner)
        return graph.enrichmentArtworkPool.open(graph.mediaClient, offer) {
            active() && coverOwner.get() === owner && valid()
        }.also { artwork = it; it.start() }
    }
    fun close() { if (gate.retire()) { retireArtwork(); calls.cancel() } }
}

internal sealed interface EnrichmentApplyState {
    data object Ready : EnrichmentApplyState
    data object Applying : EnrichmentApplyState
    data object Refused : EnrichmentApplyState
    class NeedsReadback(val receipt: MetadataApplyResult.Unconfirmed) : EnrichmentApplyState
    data object Checking : EnrichmentApplyState
    data object Confirmed : EnrichmentApplyState

    val canApply get() = this == Ready || this == Refused
    val busy get() = this == Applying || this == Checking

    companion object {
        fun settled(result: MetadataApplyResult): EnrichmentApplyState = when (result) {
            MetadataApplyResult.Applied -> Confirmed
            MetadataApplyResult.Refused -> Refused
            is MetadataApplyResult.Unconfirmed -> NeedsReadback(result)
        }
    }
}

@Composable
internal fun LocalEnrichmentEditor(graph: AppGraph, visit: LocalEnrichmentVisit, routeCurrent: () -> Boolean,
    onCancel: () -> Unit, onApplied: () -> Unit) {
    val phone = graph.phoneAudio
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val route by rememberUpdatedState(routeCurrent)
    val cancel by rememberUpdatedState(onCancel)
    val phoneState by phone.state.collectAsState()
    val accountVersion by graph.session.scopeRevision.collectAsState()
    val auth by graph.session.state.collectAsState()
    val worker = rememberCoroutineScope()
    val focus = LocalFocusManager.current
    val draft = remember(visit) { LocalEnrichmentDraft.from(visit.row) }
    var title by remember(visit) { mutableStateOf(draft.title) }
    var artist by remember(visit) { mutableStateOf(draft.artist) }
    var album by remember(visit) { mutableStateOf(draft.album) }
    var includeDuration by remember(visit) { mutableStateOf(draft.durationMs != null) }
    var source by remember(visit) { mutableStateOf<PhoneEnrichmentSource?>(null) }
    var retired by remember(visit) { mutableStateOf(false) }
    var looking by remember(visit) { mutableStateOf(false) }
    var applyState by remember(visit) { mutableStateOf<EnrichmentApplyState>(EnrichmentApplyState.Ready) }
    var reply by remember(visit) { mutableStateOf<LocalEnrichmentReply?>(null) }
    var candidate by remember(visit) { mutableStateOf<LocalEnrichmentCandidate?>(null) }

    fun active() = visit.active() && route() && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
    fun retire() { visit.close(); retired = true }
    DisposableEffect(visit, lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_PAUSE || event == Lifecycle.Event.ON_STOP) {
                visit.close()
                cancel()
            }
        }
        lifecycle.addObserver(observer)
        onDispose { visit.close(); lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(visit) {
        val captured = try { phone.captureEnrichment(visit.account, visit.row, visit.gate) }
        catch (e: CancellationException) { throw e }
        catch (_: Exception) { null }
        if (captured == null || !active() || !phone.enrichmentCurrent(captured)) retire()
        else source = captured
    }
    LaunchedEffect(phoneState, accountVersion, auth, source, applyState) {
        // The acknowledged Apply itself changes the text revision; do not retire its UI ahead
        // of its receipt. The repository still checks the old revision at the atomic write.
        if (!graph.session.current(visit.account) || source?.let { applyState.canApply && !phone.enrichmentCurrent(it) } == true) retire()
    }

    if (retired) {
        Text("The phone file or account changed. Reopen Enrich to look it up again.")
    } else if (source == null) {
        Text("Checking phone file…")
    } else {
        val captured = requireNotNull(source)
        val matches = reply as? LocalEnrichmentReply.Suggestions
        if (matches == null) {
            Text("SoundQ sends the fields below to your signed-in server. The server sends the title and any included artist to MusicBrainz. Album and duration are used only by your server to rank matches.")
            Text("No audio, file path, URI, fingerprint or artwork is sent.", style = SoundQ.typography.caption)
            fun canEdit() = !looking && reply !is LocalEnrichmentReply.Suggestions && active()
            SoundQTextField(title, { if (canEdit()) { title = it.take(400); reply = null } }, "Search title", enabled = !looking)
            SoundQTextField(artist, { if (canEdit()) { artist = it.take(400); reply = null } }, "Search artist (optional)", enabled = !looking)
            SoundQTextField(album, { if (canEdit()) { album = it.take(400); reply = null } }, "Search album (optional)", enabled = !looking)
            draft.durationMs?.let { duration ->
                EnrichmentToggle("Include duration: $duration ms", includeDuration, !looking) { if (canEdit()) { includeDuration = it; reply = null } }
            }
            val terms = LocalEnrichmentTerms.reviewed(title, artist, album, draft.durationMs?.takeIf { includeDuration })
            if (terms == null) Text("Enter a plain-text title and optional artist or album, without paths or file names.", style = SoundQ.typography.caption)
            val status = when (reply) {
                LocalEnrichmentReply.Ambiguous -> "MusicBrainz found similar matches. Refine the search or keep your current details."
                LocalEnrichmentReply.NoMatch -> "No match found."
                LocalEnrichmentReply.Disabled -> "Enrich is not available on this server."
                LocalEnrichmentReply.SignIn -> "Sign in again before looking up metadata."
                LocalEnrichmentReply.Busy -> "Lookup is busy. Try again."
                LocalEnrichmentReply.InvalidTerms -> "The server could not use those search terms. Edit them and try again."
                LocalEnrichmentReply.Unavailable -> "Lookup is unavailable. Try again."
                else -> null
            }
            status?.let { Text(it) }
            SoundQButton(if (looking) "Looking up…" else "Look up metadata", {
                // Do not send an IME edit that has not yet been rendered in this disclosure.
                if (terms != null && title == terms.title && artist == terms.artist.orEmpty() && album == terms.album.orEmpty() &&
                    draft.durationMs?.takeIf { includeDuration } == terms.durationMs && canEdit() &&
                    reply != LocalEnrichmentReply.Disabled && reply != LocalEnrichmentReply.SignIn &&
                    phone.enrichmentCurrent(captured) && graph.session.remoteCurrent(visit.account)) {
                    looking = true; reply = null; candidate = null; focus.clearFocus()
                    worker.launch {
                        val outcome = try {
                            withContext(Dispatchers.IO) { graph.api.localEnrichment(visit.account, terms, visit.calls) { active() && phone.enrichmentCurrent(captured) } }
                        } catch (e: CancellationException) { throw e }
                        catch (e: SafeFailure) {
                            if (e.reason == SafeFailure.Reason.Retired) LocalEnrichmentReply.SignIn else LocalEnrichmentReply.Unavailable
                        }
                        if (active() && phone.enrichmentCurrent(captured)) { looking = false; reply = outcome }
                        else retire()
                    }
                }
            }, enabled = terms != null && !looking && reply != LocalEnrichmentReply.Disabled && reply != LocalEnrichmentReply.SignIn)
        } else {
            Text("Choose a MusicBrainz match", style = SoundQ.typography.title)
            matches.candidates.forEach { match ->
                SoundQRow(requireNotNull(match.text.title), listOfNotNull(match.text.artist, match.text.album,
                    match.durationMs?.let(::formatSongTime)).joinToString(" · "), candidate === match,
                    { if (reply === matches && applyState.canApply && active() && phone.enrichmentCurrent(captured) && candidate !== match) {
                        visit.retireArtwork(); candidate = match; applyState = EnrichmentApplyState.Ready
                    } }, enabled = applyState.canApply)
            }
            candidate?.let { match -> key(match.recording) {
                val before = captured.metadata.row
                val changes = LocalDisplayText(match.text.title?.takeUnless { it == before.displayTitle },
                    match.text.artist?.takeUnless { it == before.displayArtist }, match.text.album?.takeUnless { it == before.displayAlbum })
                var applyTitle by remember { mutableStateOf(false) }
                var applyArtist by remember { mutableStateOf(false) }
                var applyAlbum by remember { mutableStateOf(false) }
                var coverRead by remember { mutableStateOf<Pair<CaaArtworkRef, RadarArtworkPool.Lease>?>(null) }
                var applyArtwork by remember { mutableStateOf(false) }
                var preparedCover by remember { mutableStateOf<LocalAppliedCover?>(null) }
                fun reviewOwned() = active() && reply === matches && candidate === match
                fun reviewCurrent() = reviewOwned() && phone.enrichmentCurrent(captured)
                Text("Review track details", style = SoundQ.typography.title)
                EnrichmentDifference("Title", before.displayTitle, match.text.title, applyTitle, applyState.canApply) { if (applyState.canApply) applyTitle = it }
                EnrichmentDifference("Artist", before.displayArtist, match.text.artist, applyArtist, applyState.canApply) { if (applyState.canApply) applyArtist = it }
                EnrichmentDifference("Album", before.displayAlbum, match.text.album, applyAlbum, applyState.canApply) { if (applyState.canApply) applyAlbum = it }
                val offer = match.release?.let { CaaArtworkRef.Edition(it) } ?: match.releaseGroup?.let { CaaArtworkRef.Group(it) }
                Text("Artwork", style = SoundQ.typography.title)
                if (offer != null) {
                    val (_, id) = coverProvenance(offer)
                    val label = if (offer is CaaArtworkRef.Edition) "release" else "release group"
                    Text("Public $label ID: $id", style = SoundQ.typography.caption)
                    Text("Cover Art Archive and Internet Archive receive the public artwork request and your IP address. No file, account or lookup terms are sent.",
                        style = SoundQ.typography.caption)
                    SoundQButton("Preview artwork", {
                        if (applyState.canApply && coverRead == null && reviewCurrent() && graph.session.remoteCurrent(visit.account)) {
                            applyState = EnrichmentApplyState.Ready
                            coverRead = offer to visit.startArtwork(graph, offer) { reviewCurrent() && graph.session.remoteCurrent(visit.account) }
                        }
                    }, variant = SoundQButtonVariant.Secondary, enabled = applyState.canApply && coverRead == null)
                }
                val read = coverRead
                val lease = read?.second
                val finished = lease?.finished?.collectAsState()?.value == true
                val pixels = lease?.state?.collectAsState()?.value
                var encoded by remember(lease) { mutableStateOf(false) }
                LaunchedEffect(lease, finished, pixels) {
                    if (read != null && lease != null && finished) {
                        val cover = pixels?.let { image -> withContext(Dispatchers.IO) { encodeLocalCover(read.first, image) } }
                        if (coverRead?.second === lease && reviewCurrent() && lease.current()) preparedCover = cover
                        encoded = true
                    }
                }
                EnrichmentArtworkPair(current = {
                    PhoneArtwork(graph, phone.reference(before), 72.dp, ::reviewCurrent)
                }, suggested = {
                    if (lease != null && pixels != null) ArtworkPaint(lease.state, lease::bitmap, remember(lease) { AtomicBoolean(true) }, 72.dp)
                    else Text(when {
                        lease == null -> if (offer == null) "No artwork" else "Not previewed"
                        !encoded -> "Loading artwork…"
                        else -> "No artwork"
                    })
                })
                if (lease != null && encoded && preparedCover != null && preparedCover != before.displayOverride?.artwork) {
                    EnrichmentToggle("Use previewed artwork", applyArtwork, applyState.canApply) {
                        if (applyState.canApply && coverRead?.second === lease && reviewCurrent() && lease.current()) applyArtwork = it
                    }
                }
                Text("Changes apply in SoundQ, not to your phone file.", style = SoundQ.typography.caption)
                fun settle(result: MetadataApplyResult) {
                    if (!active() || !graph.session.current(visit.account)) { retire(); return }
                    applyState = EnrichmentApplyState.settled(result)
                    when (applyState) {
                        EnrichmentApplyState.Confirmed -> { visit.close(); onApplied() }
                        EnrichmentApplyState.Refused -> if (!phone.enrichmentCurrent(captured)) retire()
                        else -> Unit
                    }
                }
                when (val status = applyState) {
                    is EnrichmentApplyState.NeedsReadback -> {
                        Text("Save not confirmed.", color = SoundQ.colors.error)
                        SoundQButton("Check saved details", {
                            if (applyState === status && reviewOwned()) {
                                applyState = EnrichmentApplyState.Checking
                                worker.launch { settle(phone.checkEnrichment(captured, status.receipt)) }
                            }
                        })
                    }
                    EnrichmentApplyState.Checking -> Text("Checking saved details…")
                    else -> {
                        if (status == EnrichmentApplyState.Refused) Text("Couldn't save these details. Try again.", color = SoundQ.colors.error)
                        SoundQButton(if (status == EnrichmentApplyState.Applying) "Applying…" else "Apply selected details", {
                            val selected = LocalDisplayText(changes.title?.takeIf { applyTitle }, changes.artist?.takeIf { applyArtist }, changes.album?.takeIf { applyAlbum })
                            val artwork = preparedCover.takeIf { applyArtwork }
                            val artworkLease = coverRead?.second
                            if (applyState.canApply && reviewOwned() && (!applyArtwork || artwork != null && artworkLease?.current() == true) &&
                                (!selected.empty || artwork != null)) {
                                applyState = EnrichmentApplyState.Applying
                                worker.launch { settle(phone.applyEnrichment(captured, selected, artwork, ::reviewOwned)) }
                            }
                        }, enabled = status.canApply && (applyTitle || applyArtist || applyAlbum || applyArtwork && preparedCover != null))
                    }
                }
            } }
            SoundQButton("Edit lookup terms", { if (reply === matches && applyState.canApply && active()) {
                visit.retireArtwork(); reply = null; candidate = null; applyState = EnrichmentApplyState.Ready
            } },
                variant = SoundQButtonVariant.Secondary, enabled = applyState.canApply)
        }
    }
    SoundQButton(when {
        applyState is EnrichmentApplyState.NeedsReadback || applyState == EnrichmentApplyState.Checking -> "Close"
        candidate != null && !retired -> "Keep current details"
        else -> "Cancel"
    }, onCancel, variant = SoundQButtonVariant.Secondary, enabled = retired || !applyState.busy)
}

private fun coverProvenance(offer: CaaArtworkRef) = when (offer) {
    is CaaArtworkRef.Edition -> LocalAppliedCover.Kind.RELEASE to offer.id.value
    is CaaArtworkRef.Group -> LocalAppliedCover.Kind.RELEASE_GROUP to offer.id.value
}

private fun encodeLocalCover(offer: CaaArtworkRef, image: Bitmap): LocalAppliedCover? = runCatching {
    val (kind, id) = coverProvenance(offer)
    val out = ByteArrayOutputStream()
    if (!image.compress(Bitmap.CompressFormat.JPEG, 85, out)) return null
    LocalAppliedCover.encoded(kind, id, out.toByteArray())
}.getOrNull()

@Composable
private fun EnrichmentDifference(label: String, current: String?, proposed: String?, selected: Boolean,
    enabled: Boolean, toggle: (Boolean) -> Unit) {
    val before = current?.takeIf { it.isNotBlank() } ?: "Not set"
    Column(Modifier.fillMaxWidth().testTag("enrich-field-${label.lowercase()}")) {
        Text(label, Modifier.fillMaxWidth(), style = SoundQ.typography.title)
        Text("$label · Current: $before", Modifier.fillMaxWidth())
        Text("$label · Suggested: ${proposed ?: "Not offered"}", Modifier.fillMaxWidth())
        if (proposed != null && proposed != current) EnrichmentToggle("Use suggested ${label.lowercase()}: $proposed", selected, enabled, toggle)
        else Text("Unchanged", Modifier.fillMaxWidth(), style = SoundQ.typography.caption)
    }
}

@Composable
private fun EnrichmentArtworkPair(current: @Composable () -> Unit, suggested: @Composable () -> Unit) {
    val pair: @Composable () -> Unit = {
        Column(Modifier.testTag("enrich-current-cover"), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Current", style = SoundQ.typography.caption)
            Box(Modifier.testTag("enrich-current-cover-pixels")) { current() }
        }
        Column(Modifier.testTag("enrich-suggested-cover"), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Suggested", style = SoundQ.typography.caption)
            Box(Modifier.testTag("enrich-suggested-cover-pixels")) { suggested() }
        }
    }
    if (LocalDensity.current.fontScale >= 1.30f) Column(Modifier.fillMaxWidth().testTag("enrich-artwork-pair"),
        verticalArrangement = Arrangement.spacedBy(SoundQ.spacing.medium)) { pair() }
    else Row(Modifier.fillMaxWidth().testTag("enrich-artwork-pair"),
        horizontalArrangement = Arrangement.spacedBy(SoundQ.spacing.medium)) { pair() }
}

@Composable
private fun EnrichmentToggle(label: String, selected: Boolean, enabled: Boolean, change: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = SoundQ.sizes.row).toggleable(selected, enabled = enabled, role = Role.Checkbox, onValueChange = change),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(SoundQ.spacing.medium)) {
        Checkbox(selected, null, enabled = enabled, colors = CheckboxDefaults.colors(checkedColor = SoundQ.colors.primary, checkmarkColor = SoundQ.colors.onPrimary))
        Text(label, Modifier.weight(1f), style = SoundQ.typography.body)
    }
}
