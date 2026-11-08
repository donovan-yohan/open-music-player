// Additive design mapping; canonical export remains unchanged. Not native compiled.
package soundq.design.generated

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

object SoundQQuickQueueRoles {
    private val canonical = SoundQComposeTokens
    val reveal: Dp = canonical.MOTION_ROW_REVEAL
    const val armExtraRowHeightRatio: Float = 0.5f
    val armExtraMin: Dp = 48.dp
    val armExtraMax: Dp = 80.dp
    val overtravel: Dp = 24.dp
    val remainingFrontMin: Dp = 48.dp
    val armedForeground = canonical.SEMANTIC_COLOR_TEXT
    val armedBackground = canonical.SEMANTIC_COLOR_RAISED
    val armedKeylineWidth: Dp = canonical.SEMANTIC_DIMENSION_FOCUS_WIDTH
    val targetMin: Dp = canonical.SEMANTIC_DIMENSION_TARGET_MIN
    val slop: Dp = canonical.MOTION_GESTURE_SLOP
    const val axisRatio: Float = SoundQComposeTokens.MOTION_GESTURE_AXIS_RATIO
    const val revealFraction: Float = SoundQComposeTokens.MOTION_ROW_COMMIT_PROGRESS
    const val returnDurationMs: Int = SoundQComposeTokens.MOTION_DURATION_SETTLE
    const val reducedDurationMs: Int = SoundQComposeTokens.MOTION_DURATION_REDUCED
    val returnEasing = canonical.MOTION_EASING_STANDARD
    fun armDistance(rowHeight: Dp): Dp =
        reveal + (rowHeight * armExtraRowHeightRatio).coerceIn(armExtraMin, armExtraMax)
    fun maxTravel(rowHeight: Dp): Dp = armDistance(rowHeight) + overtravel
    fun shortcutFits(rowWidth: Dp, rowHeight: Dp): Boolean =
        rowWidth >= armDistance(rowHeight) + remainingFrontMin
}

enum class QuickQueuePhase { Closed, Revealed, Tracking, Armed, Pending, Accepted, Rejected }
enum class QuickQueueHapticIntent { LightThresholdCrossing }
// Application owns captured identity/context validity and request idempotency.
data class QuickQueueRequest<Row, Context>(val row: Row, val context: Context, val sessionId: String)
