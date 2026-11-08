package com.soundq.designsystem

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.*
import androidx.compose.ui.input.pointer.*
import androidx.compose.ui.platform.*
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.style.TextAlign
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.abs

/** Input readiness only; this is NOT an audio acknowledgement or persistence receipt. */
@Immutable
data class PrecisionBpmControlStatus(
    val isEditing: Boolean = false,
    val isGliding: Boolean = false,
    val isCandidateActive: Boolean = false,
    val validationError: String? = null,
    val canSubmit: Boolean = false,
)

/**
 * Controlled sheet body. Place inside a bounded, non-scrolling precision region of SoundQSheet.
 * Parent owns title/close, safe-area/IME padding, scrolling around this body, transaction and footer.
 * Key the composition to the source/occurrence lifetime; change [interruptionKey] on Cancel/Save/
 * invalidation. Disposal permanently retires frames; owner performs its own asynchronous rollback.
 * [onAdjustmentCancel] terminates an INPUT, not the entire sheet preview lease.
 */
@Composable
fun PrecisionBpmControl(
    value: Double,
    original: Double?,
    range: ClosedFloatingPointRange<Double>,
    onDraft: (Double) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    pending: Boolean = false,
    error: String? = null,
    disabledReason: String? = null,
    interruptionKey: Any? = Unit,
    onAdjustmentBegin: () -> Unit = {},
    onAdjustmentEnd: () -> Unit = {},
    onAdjustmentCancel: () -> Unit = {},
    onCandidateActiveChange: (Boolean) -> Unit = {},
    onInputStateChange: (PrecisionBpmControlStatus) -> Unit = {},
    onCancelRequest: () -> Unit = {},
    retry: (@Composable () -> Unit)? = null,
    footer: @Composable (PrecisionBpmControlStatus) -> Unit = {},
) {
    val colors = SoundQ.colors
    val reducedMotion = SoundQ.motion.reduced
    val density = LocalDensity.current
    val keyboard = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current
    val focusRequester = remember { FocusRequester() }
    val scope = rememberCoroutineScope()
    val latestValue by rememberUpdatedState(value)
    val draftCallback by rememberUpdatedState(onDraft)
    val beginCallback by rememberUpdatedState(onAdjustmentBegin)
    val endCallback by rememberUpdatedState(onAdjustmentEnd)
    val cancelCallback by rememberUpdatedState(onAdjustmentCancel)
    val candidateCallback by rememberUpdatedState(onCandidateActiveChange)
    val stateCallback by rememberUpdatedState(onInputStateChange)
    val closeCallback by rememberUpdatedState(onCancelRequest)
    val validRange = range.start.isFinite() && range.endInclusive.isFinite() && range.start > 0.0 && range.endInclusive >= range.start
    val available = enabled && !pending && validRange && value.isFinite() && value in range
    val canReset = available && original != null && original.isFinite() && original in range
    val intent = remember { PrecisionBpmIntent() }
    var glideJob by remember { mutableStateOf<Job?>(null) }
    var gliding by remember { mutableStateOf(false) }
    var adjusting by remember { mutableStateOf(false) }
    var candidate by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var keyboardDismissed by remember { mutableStateOf(false) }
    var text by remember { mutableStateOf(TextFieldValue("")) }
    var horizontal by remember { mutableDoubleStateOf(.5) }
    var announcement by remember { mutableStateOf("") }
    var contactToken by remember { mutableLongStateOf(0L) }
    val input = remember(range.start, range.endInclusive) {
        PrecisionBpmInputController(range,
            { if (intent.accepts(contactToken)) { adjusting = true; beginCallback() } },
            { if (intent.accepts(contactToken)) draftCallback(it) },
            { if (intent.accepts(contactToken)) { adjusting = false; announcement = "${formatPrecisionBpm(latestValue)} BPM"; endCallback() } },
            { if (intent.accepts(contactToken)) { adjusting = false; cancelCallback() } })
    }
    fun setCandidate(active: Boolean) {
        if (candidate != active) { candidate = active; candidateCallback(active) }
    }
    fun supersede() {
        intent.next()
        glideJob?.cancel(); glideJob = null
        if (gliding) { gliding = false; endCallback() }
    }
    fun finishTyping() {
        // Done never commits. Keep invalid text and its correction visible.
        keyboard?.hide(); keyboardDismissed = true
        if (parsePrecisionBpmText(text.text, range).value != null) {
            editing = false; focusManager.clearFocus(); endCallback()
        }
    }
    fun typeValue(): Boolean {
        if (!available || !intent.isAlive) return false
        supersede(); input.cancelPointer()
        if (!editing) {
            val formatted = formatPrecisionBpm(latestValue)
            text = TextFieldValue(formatted, TextRange(0, formatted.length))
            editing = true; keyboardDismissed = false; beginCallback()
        }
        return true
    }
    fun adjust(next: Double): Boolean {
        if (!available || !intent.isAlive || editing || !next.isFinite()) return false
        supersede(); input.cancelPointer()
        beginCallback(); draftCallback(next.coerceIn(range.start, range.endInclusive)); endCallback()
        announcement = "${formatPrecisionBpm(next.coerceIn(range.start, range.endInclusive))} BPM"
        return true
    }
    fun reset(immediate: Boolean) {
        if (!canReset || !intent.isAlive) return
        supersede(); input.cancelPointer()
        if (editing) { editing = false; keyboard?.hide(); focusManager.clearFocus(); endCallback() }
        val target = original
        val from = latestValue
        val token = intent.next()
        beginCallback()
        if (immediate || reducedMotion || from == target) {
            draftCallback(target); endCallback(); announcement = "${formatPrecisionBpm(target)} BPM"
        } else {
            gliding = true
            glideJob = scope.launch {
                val start = withFrameNanos { it }
                while (intent.accepts(token)) {
                    val frame = withFrameNanos { it }
                    if (!intent.accepts(token)) break
                    val t = ((frame - start).toDouble() / 450_000_000.0).coerceIn(0.0, 1.0)
                    draftCallback(precisionBpmReset(from, target, t))
                    if (t >= 1.0) {
                        gliding = false; glideJob = null; endCallback()
                        announcement = "${formatPrecisionBpm(target)} BPM"
                        break
                    }
                }
            }
        }
    }
    val parsed = if (editing) parsePrecisionBpmText(text.text, range) else null
    val status = PrecisionBpmControlStatus(editing, gliding, candidate, parsed?.error,
        available && !gliding && !candidate && parsed?.error == null && error == null)
    SideEffect { stateCallback(status) }
    DisposableEffect(intent) {
        onDispose {
            intent.dispose(); glideJob?.cancel()
            // No onDraft on disposal: only the parent's preview owner may reconcile accepted state.
            if (candidate) candidateCallback(false)
            if (adjusting || gliding || editing) cancelCallback()
        }
    }
    // Retire the old input during apply, not in a coroutine dispatched after the new key is accepted.
    DisposableEffect(interruptionKey, available, range.start, range.endInclusive, original, input) {
        supersede(); input.cancelPointer(); adjusting = false; setCandidate(false)
        if (editing) { editing = false; keyboard?.hide(); focusManager.clearFocus(); cancelCallback() }
        onDispose {
            // Key replacement/removal must revoke old frames before any replacement input can run.
            intent.next(); glideJob?.cancel()
        }
    }
    LaunchedEffect(editing) {
        if (editing) { focusRequester.requestFocus(); keyboard?.show() }
    }
    val relation = precisionBpmInputRelation(value, original, parsed)
    val valueColor = if (!available) colors.disabled else when (relation) {
        BpmRelation.Above -> colors.primary
        BpmRelation.Below -> colors.secondary
        else -> colors.text
    }
    val direction = when (relation) {
        BpmRelation.Above -> "Above original"
        BpmRelation.Below -> "Below original"
        BpmRelation.Original -> "At original"
        null -> if (parsed?.error != null) "Enter a valid BPM" else "Original BPM unavailable"
    }
    val signedDelta = if (relation == null) "" else {
        val delta = value - original!!
        " · ${if (delta > 0) "+" else if (delta < 0) "−" else ""}${formatPrecisionBpm(abs(delta))} BPM"
    }
    Column(modifier.fillMaxWidth().background(colors.sheet)) {
        Row(Modifier.fillMaxWidth().padding(start = SoundQ.spacing.gutter), verticalAlignment = Alignment.CenterVertically) {
            Text(if (original != null && original.isFinite()) "Original ${formatPrecisionBpm(original)} BPM" else "Original BPM unavailable",
                Modifier.weight(1f), color = colors.muted, style = SoundQ.typography.mono)
            PrecisionBpmResetButton(canReset, "Reset to original ${original?.let(::formatPrecisionBpm) ?: "unavailable"} BPM",
                interruptionKey = listOf(interruptionKey, original, range.start, range.endInclusive), onDown = { supersede() }, onSingle = { reset(false) }, onDoubleDown = { reset(true) })
        }
        BoxWithConstraints(Modifier.fillMaxWidth()) {
        // Keep 600.00 complete at short widths/enlarged text; only display decoration scales down.
        val heroSp = minOf(64f, ((maxWidth - SoundQ.spacing.gutter * 2).value / (6f * .62f * density.fontScale))).coerceAtLeast(20f)
        val heroStyle = SoundQ.typography.mono.copy(fontSize = heroSp.sp, lineHeight = (heroSp * 1.1875f).sp, letterSpacing = 0.sp,
            fontFeatureSettings = "tnum", color = valueColor, textAlign = TextAlign.End)
        if (editing) {
            BasicTextField(value = text, onValueChange = { next ->
                // Retain rejected text, including a third fractional digit, rather than truncate it.
                val changed = next.text != text.text
                supersede(); text = next
                if (changed) parsePrecisionBpmText(next.text, range).value?.let { draftCallback(it) }
            }, modifier = Modifier.fillMaxWidth().padding(horizontal = SoundQ.spacing.gutter)
                .testTag("precision-bpm-editor").focusRequester(focusRequester)
                .onPreviewKeyEvent {
                    if (it.type == KeyEventType.KeyDown && it.key == Key.Escape) {
                        if (!keyboardDismissed) { keyboard?.hide(); keyboardDismissed = true }
                        else { supersede(); closeCallback() }
                        true
                    } else false
                }.semantics { contentDescription = "Type BPM" },
                textStyle = heroStyle, singleLine = true, cursorBrush = SolidColor(colors.focus),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { finishTyping() }))
        } else {
            Column(Modifier.fillMaxWidth().heightIn(min = 176.dp).testTag("precision-bpm-surface")
                .onPreviewKeyEvent { event ->
                    if (event.type != KeyEventType.KeyDown) false else when (event.key) {
                        Key.DirectionUp -> adjust(latestValue + if (event.isShiftPressed) 1.0 else .01)
                        Key.DirectionDown -> adjust(latestValue - if (event.isShiftPressed) 1.0 else .01)
                        Key.MoveHome -> adjust(range.start)
                        Key.MoveEnd -> adjust(range.endInclusive)
                        Key.Enter, Key.NumPadEnter -> typeValue()
                        Key.Escape -> {
                            if (candidate) { input.cancelPointer(); supersede(); setCandidate(false) }
                            else { supersede(); closeCallback() }
                            true
                        }
                        else -> false
                    }
                }.focusable(enabled = available)
                .semantics(mergeDescendants = true) {
                    contentDescription = "Playback BPM"
                    stateDescription = "${formatPrecisionBpm(value)} BPM. $direction$signedDelta"
                    if (!available) disabled()
                    if (validRange && value.isFinite()) progressBarRangeInfo = ProgressBarRangeInfo(value.toFloat(), range.start.toFloat()..range.endInclusive.toFloat())
                    setProgress { adjust(it.toDouble()) }
                    onClick(label = "Type BPM") { typeValue() }
                    customActions = listOf(
                        CustomAccessibilityAction("Increase 0.01 BPM") { adjust(latestValue + .01) },
                        CustomAccessibilityAction("Decrease 0.01 BPM") { adjust(latestValue - .01) },
                        CustomAccessibilityAction("Increase 1 BPM") { adjust(latestValue + 1) },
                        CustomAccessibilityAction("Decrease 1 BPM") { adjust(latestValue - 1) },
                        CustomAccessibilityAction("Type BPM") { typeValue() })
                }
                .pointerInput(available, interruptionKey, range.start, range.endInclusive, input) {
                    if (!available) return@pointerInput
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                        supersede(); contactToken = intent.next(); setCandidate(true)
                        val width = size.width.toDouble().coerceAtLeast(1.0)
                        input.pointerDown(latestValue, down.position.x / width, down.position.y / density.density.toDouble(), viewConfiguration.touchSlop / density.density.toDouble(), viewConfiguration.touchSlop / width)
                        down.consume()
                        var blocked = currentEvent.changes.any { it.id != down.id && it.pressed }
                        if (blocked) input.cancelPointer()
                        try {
                            while (true) {
                                val event = awaitPointerEvent(PointerEventPass.Initial)
                                // Compose maps Android ACTION_CANCEL to consumed synthetic all-up.
                                // Inspect before consuming our own packet, and never finish that input.
                                if (event.changes.any { it.isConsumed }) {
                                    blocked = true; input.cancelPointer()
                                }
                                // Detect another contact even if the original lifts in this event.
                                if (event.changes.any { it.id != down.id && (it.pressed || it.previousPressed) }) {
                                    blocked = true; input.cancelPointer()
                                }
                                val change = event.changes.firstOrNull { it.id == down.id }
                                if (!blocked && change != null) {
                                    horizontal = (change.position.x / width).coerceIn(0.0, 1.0)
                                    input.pointerMove(change.position.x / width, change.position.y / density.density.toDouble())
                                    if (!change.pressed) {
                                        val tap = input.pointerUp()
                                        // Only the numeral area is a type affordance, not the whole helper.
                                        if (tap && down.position.y <= 88.dp.toPx()) typeValue()
                                        blocked = true
                                    }
                                }
                                event.changes.forEach { it.consume() }
                                if (event.changes.none { it.pressed }) break
                            }
                        } finally {
                            input.cancelPointer(); setCandidate(false)
                        }
                    }
                }.padding(horizontal = SoundQ.spacing.gutter)) {
                Text(formatPrecisionBpm(value), Modifier.fillMaxWidth(), color = valueColor, style = heroStyle, maxLines = 1, softWrap = false)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Coarse", color = colors.muted, style = SoundQ.typography.caption)
                    Text("Fine", color = colors.muted, style = SoundQ.typography.caption)
                }
                Canvas(Modifier.fillMaxWidth().height(16.dp)) {
                    drawLine(colors.border, androidx.compose.ui.geometry.Offset(0f, size.height / 2), androidx.compose.ui.geometry.Offset(size.width, size.height / 2), 1.dp.toPx())
                    val x = (size.width * horizontal).toFloat()
                    drawLine(valueColor, androidx.compose.ui.geometry.Offset(x, 0f), androidx.compose.ui.geometry.Offset(x, size.height), 2.dp.toPx())
                }
                Text("Slide up / down · move right for finer control", color = colors.muted, style = SoundQ.typography.caption)
            }
        }
        }
        Column(Modifier.fillMaxWidth().padding(horizontal = SoundQ.spacing.gutter, vertical = SoundQ.spacing.small)) {
            Text(if (gliding) "Returning to original" else direction + signedDelta, color = valueColor, style = SoundQ.typography.caption)
            Text("Range ${formatPrecisionBpm(range.start)}–${formatPrecisionBpm(range.endInclusive)} BPM", color = colors.muted, style = SoundQ.typography.mono)
            val message = parsed?.error ?: error ?: if (!available) disabledReason ?: if (pending) "Updating BPM…" else "BPM editing unavailable." else null
            if (message != null) Text(message, Modifier.semantics { liveRegion = LiveRegionMode.Polite }, color = if (parsed?.error != null || error != null) colors.error else colors.muted, style = SoundQ.typography.caption)
            if (!available) retry?.invoke()
            // Release-only live announcement; don't announce every dragged hundredth/frame.
            Box(Modifier.size(0.dp).semantics { liveRegion = LiveRegionMode.Polite; contentDescription = announcement })
        }
        footer(status)
    }
}

/** Consume one reset contact through ALL-up; moving or adding a pointer never clicks. */
private suspend fun AwaitPointerEventScope.awaitPrecisionBpmResetUp(down: PointerInputChange): PointerInputChange? {
    var cancelled = currentEvent.changes.count { it.pressed } != 1
    var released: PointerInputChange? = null
    while (true) {
        val event = awaitPointerEvent(PointerEventPass.Initial)
        // A synthetic Android cancel is all-up too, but its down change is already consumed.
        if (event.changes.any { it.isConsumed }) cancelled = true
        if (event.changes.any { it.id != down.id && (it.pressed || it.previousPressed) }) cancelled = true
        val change = event.changes.firstOrNull { it.id == down.id }
        if (change != null) {
            if ((change.position - down.position).getDistance() > viewConfiguration.touchSlop) cancelled = true
            if (!change.pressed) released = change
        }
        event.changes.forEach { it.consume() }
        if (event.changes.none { it.pressed }) return if (cancelled) null else released
    }
}

/** Native pointer packets, platform tap timing; first release starts now, second DOWN snaps now. */
@Composable
private fun PrecisionBpmResetButton(enabled: Boolean, label: String, interruptionKey: Any?, onDown: () -> Unit, onSingle: () -> Unit, onDoubleDown: () -> Unit) {
    val colors = SoundQ.colors
    val latestDown by rememberUpdatedState(onDown)
    val latestSingle by rememberUpdatedState(onSingle)
    val latestDouble by rememberUpdatedState(onDoubleDown)
    val doubleSlop = android.view.ViewConfiguration.get(LocalContext.current).scaledDoubleTapSlop.toFloat()
    Box(Modifier.size(48.dp).testTag("precision-bpm-reset").border(SoundQ.sizes.border, colors.border)
        .semantics {
            role = Role.Button; contentDescription = label
            if (!enabled) disabled()
            onClick { if (enabled) latestSingle(); enabled }
            customActions = listOf(CustomAccessibilityAction("Reset immediately") { if (enabled) latestDouble(); enabled })
        }.onPreviewKeyEvent {
            if (enabled && it.type == KeyEventType.KeyUp && (it.key == Key.Enter || it.key == Key.Spacebar)) { latestSingle(); true } else false
        }.focusable(enabled)
        .pointerInput(enabled, doubleSlop, interruptionKey) {
            if (!enabled) return@pointerInput
            awaitEachGesture {
                val first = awaitFirstDown(pass = PointerEventPass.Initial)
                latestDown(); first.consume()
                val up = awaitPrecisionBpmResetUp(first)
                if (up != null) {
                    up.consume(); latestSingle()
                    val second = withTimeoutOrNull(viewConfiguration.doubleTapTimeoutMillis) {
                        var next = awaitFirstDown(pass = PointerEventPass.Initial)
                        while (next.uptimeMillis - up.uptimeMillis < viewConfiguration.doubleTapMinTimeMillis) {
                            next.consume(); awaitPrecisionBpmResetUp(next)
                            next = awaitFirstDown(pass = PointerEventPass.Initial)
                        }
                        next
                    }
                    if (second != null) {
                        latestDown(); second.consume()
                        val qualifies = second.uptimeMillis - up.uptimeMillis <= viewConfiguration.doubleTapTimeoutMillis &&
                            (second.position - first.position).getDistance() <= doubleSlop
                        if (qualifies) latestDouble()
                        val secondUp = awaitPrecisionBpmResetUp(second)
                        secondUp?.consume()
                        if (!qualifies && secondUp != null) latestSingle()
                    }
                }
            }
        }, contentAlignment = Alignment.Center) {
        SoundQIcon(SoundQIcon.Retry, null, tint = if (enabled) colors.text else colors.disabled)
    }
}
