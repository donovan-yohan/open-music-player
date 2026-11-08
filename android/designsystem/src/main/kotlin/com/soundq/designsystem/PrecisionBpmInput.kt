package com.soundq.designsystem

/** Text admission is deliberately separate from drag precision. Invalid text stays visible. */
internal data class PrecisionBpmText(val value: Double?, val error: String?)
internal fun parsePrecisionBpmText(text: String, range: ClosedFloatingPointRange<Double>): PrecisionBpmText {
    val normalized = text.replace(',', '.')
    if (!Regex("[0-9]+(?:\\.[0-9]{1,2})?").matches(normalized)) {
        return PrecisionBpmText(null, "Enter a BPM with up to two decimal places.")
    }
    val value = normalized.toDoubleOrNull()
    if (value == null || !value.isFinite() || value !in range) {
        return PrecisionBpmText(null, "Enter a BPM from ${formatPrecisionBpm(range.start)} to ${formatPrecisionBpm(range.endInclusive)}.")
    }
    return PrecisionBpmText(value, null)
}
internal fun formatPrecisionBpm(value: Double): String = String.format(java.util.Locale.ROOT, "%.2f", value)

/** The accepted draft remains full precision; invalid editor text has no directional relation. */
internal fun precisionBpmInputRelation(value: Double, original: Double?, text: PrecisionBpmText?): BpmRelation? =
    if (text?.error == null && original != null && original.isFinite() && value.isFinite()) bpmRelation(value, original) else null

/** Every new input retires every older animation frame, including retained callbacks. */
internal class PrecisionBpmIntent {
    private var generation = 0L
    private var alive = true
    val isAlive: Boolean get() = alive
    fun next(): Long = ++generation
    fun accepts(token: Long): Boolean = alive && token == generation
    fun dispose() { alive = false; generation++ }
}

/** Contact/slop arbitration over the parent-owned analytic integrator. No transport state. */
internal class PrecisionBpmInputController(
    private val range: ClosedFloatingPointRange<Double>,
    private val onBegin: () -> Unit,
    private val onDraft: (Double) -> Unit,
    private val onEnd: () -> Unit,
    private val onCancel: () -> Unit,
) {
    private var gesture: PrecisionBpmGesture? = null
    private var origin = 0.0
    private var downY = 0.0
    private var downX = 0.0
    private var horizontalSlop = 0.0
    private var lastX = 0.0
    private var lastY = 0.0
    private var slop = 0.0
    private var contact = false
    private var moved = false
    var captured = false
        private set

    fun pointerDown(value: Double, x: Double, yDp: Double, slopDp: Double, horizontalSlop: Double = 0.0) {
        check(!contact)
        contact = true; captured = false; moved = false
        origin = value; downY = yDp; downX = x; lastX = x; lastY = yDp; slop = slopDp
        this.horizontalSlop = horizontalSlop
    }
    fun pointerMove(x: Double, yDp: Double) {
        if (!contact) return
        if (kotlin.math.abs(x - downX) > horizontalSlop || kotlin.math.abs(yDp - downY) > slop) moved = true
        if (!captured && kotlin.math.abs(yDp - downY) > slop) {
            captured = true
            val boundaryY = downY + kotlin.math.sign(yDp - downY) * slop
            // Interpolate x at the vertical-slop crossing along this delivered segment.
            val fraction = if (yDp == lastY) 1.0 else ((boundaryY - lastY) / (yDp - lastY)).coerceIn(0.0, 1.0)
            val boundaryX = lastX + (x - lastX) * fraction
            gesture = PrecisionBpmGesture(origin, range.start, range.endInclusive, boundaryX, boundaryY)
            onBegin()
        }
        if (captured) onDraft(gesture!!.move(x, yDp))
        lastX = x; lastY = yDp
    }
    /** True only for an unmoved tap. Horizontal motion is never promoted to a drag. */
    fun pointerUp(): Boolean {
        if (!contact) return false
        contact = false
        val tap = !captured && !moved
        if (captured) { gesture!!.finish(); onEnd() }
        gesture = null; captured = false
        return tap
    }
    fun cancelPointer() {
        if (!contact) return
        contact = false
        if (captured) { onDraft(gesture!!.cancel()); onCancel() }
        gesture = null; captured = false
    }
}
