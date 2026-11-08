package com.soundq.design.contracts

import androidx.compose.runtime.Immutable
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.Dp

/** Visual implementation-input contract, not compiled/native-accepted in this design release. */
@JvmInline value class QueueOccurrenceKey(val value: String)
@JvmInline value class QueueVisualRevision(val value: Long)
@JvmInline value class QueuePosition(val value: Int)
@JvmInline value class QueueScrollDpPerMillisecond(val value: Float)
@JvmInline value class QueueSettleMilliseconds(val value: Int)

@Immutable
data class QueueDragMetrics(
    val handleTarget: Dp,
    val edgeZone: Dp,
    val edgeScrollSpeed: QueueScrollDpPerMillisecond,
    val settleDuration: QueueSettleMilliseconds,
)

@Immutable
data class QueueGripVisualState(
    val occurrence: QueueOccurrenceKey,
    val revision: QueueVisualRevision,
    val position: QueuePosition,
    val entryCount: Int,
    val enabled: Boolean,
    val dragging: Boolean,
    val canMoveEarlier: Boolean,
    val canMoveLater: Boolean,
    val accessibleName: String,
)

@Immutable
data class QueueInsertionPreview(
    val occurrence: QueueOccurrenceKey,
    val revision: QueueVisualRevision,
    val from: QueuePosition,
    val to: QueuePosition,
    val pointer: Offset,
)

sealed interface QueueVisualIntent {
    data class Preview(val insertion: QueueInsertionPreview) : QueueVisualIntent
    data class Commit(val insertion: QueueInsertionPreview) : QueueVisualIntent
    data class Cancel(val occurrence: QueueOccurrenceKey, val reason: QueueCancelReason) : QueueVisualIntent
    data class MoveEarlier(val occurrence: QueueOccurrenceKey, val revision: QueueVisualRevision) : QueueVisualIntent
    data class MoveLater(val occurrence: QueueOccurrenceKey, val revision: QueueVisualRevision) : QueueVisualIntent
    data class OpenActions(val occurrence: QueueOccurrenceKey) : QueueVisualIntent
    data class SelectEntry(val occurrence: QueueOccurrenceKey) : QueueVisualIntent
}

enum class QueueCancelReason { PointerCancelled, Escape, ReversedToOrigin, ViewRetired, RevisionChanged }

/**
 * A reusable purely visual queue row composes the existing content, icon button and grip.
 * It accepts QueueGripVisualState + QueueDragMetrics and emits QueueVisualIntent.
 * Its grip uses canonical SoundQIcon.Drag and a target no smaller than targetMin.
 * Its native semantics expose MoveEarlier/MoveLater custom actions when applicable.
 * Feature/controller code owns revision validation and the resulting queue snapshot.
 * No Track DTO, navigation, networking, account or Media3 service belongs here.
 */
