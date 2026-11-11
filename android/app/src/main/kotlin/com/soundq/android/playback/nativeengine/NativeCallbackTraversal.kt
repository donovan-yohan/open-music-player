package com.soundq.android.playback.nativeengine

import kotlin.random.Random

/** Index policy only. The Player is the sole owner of rows, selection and modes. */
internal object NativeCallbackTraversal {
    fun permutation(length: Int, current: Int, random: Random): List<Int> {
        if (length == 0) return emptyList()
        val selected = current.coerceIn(0, length - 1)
        val natural = (0 until length).filter { it != selected }
        val future = natural.shuffled(random).toMutableList()
        if (length > 2 && future == natural) {
            val first = future[0]
            future[0] = future[1]
            future[1] = first
        }
        return listOf(selected) + future
    }

    fun next(order: List<Int>, current: Int, repeat: Int, naturalEnd: Boolean): Int? {
        if (order.isEmpty()) return null
        if (naturalEnd && repeat == 1) return current
        val at = order.indexOf(current)
        if (at < order.lastIndex) return order[at + 1]
        return if (repeat == 2) order.first() else null
    }

    fun previous(order: List<Int>, current: Int, repeat: Int): Int {
        val at = order.indexOf(current)
        return if (at > 0) order[at - 1] else if (repeat == 2) order.last() else current
    }

    fun insert(
        order: List<Int>, index: Int, count: Int, current: Int,
        manual: Boolean, continuation: Boolean, oldManual: Set<Int>, shuffled: Boolean,
    ): List<Int> {
        if (!shuffled || order.isEmpty()) return (0 until order.size + count).toList()
        val retained = order.map { if (it >= index) it + count else it }.toMutableList()
        var slot = retained.size
        if (!continuation && manual) {
            slot = order.indexOf(current) + 1
            while (slot < order.size && order[slot] < index && order[slot] in oldManual) slot++
        } else if (!continuation && index < order.size) {
            slot = retained.indexOf(index + count)
        }
        retained.addAll(slot, (index until index + count).toList())
        return retained
    }
}
