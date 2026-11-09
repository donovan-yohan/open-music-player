package com.soundq.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation3.runtime.*
import androidx.navigation3.ui.NavDisplay
import com.soundq.android.gallery.*
import com.soundq.android.playback.PlaybackProjection
import com.soundq.designsystem.*
import kotlinx.serialization.Serializable

@Serializable data object Gallery : NavKey
@Serializable data object Infrastructure : NavKey

class MainActivity : ComponentActivity() {
    // Only the mounted system audio-picker request may temporarily leave this Activity.
    // It is never persisted and is cleared on result/disposal. No account unlock is granted.
    internal var localAudioPickerPending = false
    lateinit var deviceUnlock:com.soundq.android.localunlock.PlatformDeviceUnlock
        private set
    private var interactionRecorder:com.soundq.android.performance.WindowInteractionRecorder?=null
    internal fun beginInteractionTrace() {
        check(BuildConfig.DEBUG)
        interactionRecorder?.close()
        interactionRecorder=com.soundq.android.performance.WindowInteractionRecorder(window).also {it.start()}
    }
    internal fun endInteractionTrace(file:java.io.File) {interactionRecorder?.write(file);interactionRecorder?.close();interactionRecorder=null}
    override fun dispatchTouchEvent(event:android.view.MotionEvent):Boolean {
        val recorder=interactionRecorder ?: return super.dispatchTouchEvent(event)
        val start=android.os.SystemClock.elapsedRealtimeNanos()
        return try {super.dispatchTouchEvent(event)} finally {recorder.input(event.eventTime,start,android.os.SystemClock.elapsedRealtimeNanos())}
    }

    override fun onDestroy(){deviceUnlock.cancel();interactionRecorder?.close();interactionRecorder=null;super.onDestroy()}
    override fun onStop(){
        interactionRecorder?.stop()
        if(!isChangingConfigurations&&!deviceUnlock.credentialActivityPending&&!localAudioPickerPending) {
            deviceUnlock.cancel()
            val graph=(application as SoundQApplication).graph
            graph.localUnlock.cancel();graph.localUnlock.lock()
        }
        super.onStop()
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        deviceUnlock=com.soundq.android.localunlock.PlatformDeviceUnlock(this)
        enableEdgeToEdge()
        if(savedInstanceState==null)receiveShare(intent)
        setContent { com.soundq.android.product.ProductApp() }
    }
    override fun onNewIntent(intent:android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receiveShare(intent)
    }
    private fun receiveShare(intent:android.content.Intent?) {
        if(intent?.action!=android.content.Intent.ACTION_SEND || intent.type!="text/plain")return
        val graph=(application as SoundQApplication).graph
        val text=runCatching {intent.getCharSequenceExtra(android.content.Intent.EXTRA_TEXT)?.toString()}.getOrNull() ?: return
        graph.incomingShares.receive(text,graph.session.capture()?.accountId)
    }
}
@Composable fun SoundQApp(model: GalleryViewModel = viewModel()) {
    val state by model.state.collectAsStateWithLifecycle()
    val playback by model.playback.collectAsStateWithLifecycle()
    val stack = rememberNavBackStack(Gallery)
    SoundQTheme(reducedMotion = state.reducedMotion,appearance=if(SoundQ.colors.roles==soundq.design.generated.SoundQAppearanceMapping.dark)soundq.design.generated.SoundQAppearance.Dark else soundq.design.generated.SoundQAppearance.Light) {
        Surface(Modifier.fillMaxSize(), color = SoundQ.colors.background) {
            Box(Modifier.safeDrawingPadding().imePadding(), contentAlignment = Alignment.TopCenter) {
                NavDisplay(backStack = stack, modifier = Modifier.widthIn(max = SoundQ.sizes.appMax).fillMaxSize(), onBack = { if (stack.size > 1) stack.removeLastOrNull() },
                    entryDecorators = listOf(rememberSaveableStateHolderNavEntryDecorator()),
                    entryProvider = entryProvider {
                        entry<Gallery> { GalleryScreen(state, playback, model::query, model::select, model::reduced, { stack.add(Infrastructure) }) }
                        entry<Infrastructure> { InfrastructureScreen(playback, { stack.removeLastOrNull() }) }
                    })
            }
        }
    }
}
private data class Fixture(val id: String, val title: String, val subtitle: String)
private val fixtures = listOf(
    Fixture("fixture-1", "Orbital morning", "Synthetic artist · component fixture"),
    Fixture("fixture-2", "A deliberately long title for a distant signal beyond the quiet horizon", "Synthetic ensemble · wrapping text fixture"),
    Fixture("fixture-3", "海辺の記憶 — Étude", "Synthetic artist · Unicode fixture"),
)
@Composable internal fun GalleryScreen(state: GalleryState, playback: PlaybackProjection, onQuery: (String) -> Unit, onSelect: (String) -> Unit, onReduced: (Boolean) -> Unit, onInfrastructure: () -> Unit) {
    val listState = rememberLazyListState()
    LazyColumn(state = listState, modifier = Modifier.fillMaxSize(), contentPadding = PaddingValues(SoundQ.spacing.gutter), verticalArrangement = Arrangement.spacedBy(SoundQ.spacing.medium)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Image(painterResource(R.drawable.soundq_logo), null, Modifier.size(SoundQ.sizes.target))
                Text("SoundQ", Modifier.weight(1f), style = SoundQ.typography.heading)
                SoundQIconButton(SoundQIcon.Settings, "Open infrastructure", onInfrastructure)
            }
        }
        item { Text("Component gallery", style = SoundQ.typography.heading) }
        item { Text("Synthetic fixtures. Selection changes presentation only; no account or audio is connected.", color = SoundQ.colors.muted) }
        item { SoundQTextField(state.query, onQuery, "Filter fixtures") }
        val visible = fixtures.filter { it.title.contains(state.query, ignoreCase = true) || it.subtitle.contains(state.query, ignoreCase = true) }
        if (visible.isEmpty()) item { Text("No fixtures match. Clear the filter to restore examples.") }
        items(visible, key = { it.id }) { fixture ->
            SoundQRow(fixture.title, fixture.subtitle, state.selectedId == fixture.id, { onSelect(fixture.id) }, leading = { SoundQIcon(SoundQIcon.Note, null) }, trailing = {
                SoundQIconButton(SoundQIcon.Check, "Select ${fixture.title}", { onSelect(fixture.id) }, selected = state.selectedId == fixture.id)
            })
        }
        item { Text(if (state.selectedId == null) "No fixture selected" else "Selected: ${fixtures.first { it.id == state.selectedId }.title}", modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Reduce gallery motion", Modifier.weight(1f))
                Switch(state.reducedMotion, onReduced, modifier = Modifier.semantics { contentDescription = "Reduce gallery motion" })
            }
        }
        item { Text("Native field states", style = SoundQ.typography.title) }
        item {
            var secure by remember { mutableStateOf("") }
            SoundQTextField(secure, { secure = it }, "Password example", secure = true)
        }
        item { SoundQTextField("invalid example", {}, "Validation example", error = "Example only: a valid value is required") }
        item { SoundQTextField("Unavailable", {}, "Disabled field", enabled = false) }
        item { SoundQButton("Inspect service", onInfrastructure) }
        item { SoundQButton("Clear selection", { state.selectedId?.let(onSelect) }, variant = SoundQButtonVariant.Secondary, enabled = state.selectedId != null) }
        item { SoundQButton("Clear filter", { onQuery("") }, variant = SoundQButtonVariant.Quiet) }
        item { SoundQDivider() }
        item { Text("Listening service · ${playback.connection.name}", style = SoundQ.typography.mono) }
        item {
            SoundQRow("No media connected", "Authenticated catalog and playback are not implemented", false, {}, enabled = false, trailing = {
                SoundQIconButton(SoundQIcon.Play, "Playback unavailable", {}, enabled = false)
            })
        }
    }
}
@Composable private fun InfrastructureScreen(playback: PlaybackProjection, onBack: () -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(SoundQ.spacing.gutter), verticalArrangement = Arrangement.spacedBy(SoundQ.spacing.large)) {
        SoundQIconButton(SoundQIcon.Back, "Back to gallery", onBack)
        Text("Infrastructure", style = SoundQ.typography.heading)
        Text("Controller: ${playback.connection.name}")
        Text("One MediaLibraryService owns one ExoPlayer. The UI observes a MediaController projection. The catalog is intentionally empty and playback commands are unavailable.")
        Text("No authentication, signed-source resolution, offline library, notification acceptance, Android Auto, voice or Flutter parity is claimed.", color = SoundQ.colors.muted)
    }
}
