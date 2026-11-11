package com.soundq.android.playback.nativeengine

import kotlin.random.Random

/** Runs the production traversal functions on JVM; Android ownership tests are separate. */
fun main() {
    val first = NativeCallbackTraversal.permutation(5, 2, Random(19))
    check(first.first() == 2)
    check(first.sorted() == (0..4).toList())
    check(first == NativeCallbackTraversal.permutation(5, 2, Random(19)))
    val order = listOf(2, 4, 1, 0, 3)
    check(NativeCallbackTraversal.next(order, 2, 0, false) == 4)
    check(NativeCallbackTraversal.next(order, 2, 1, true) == 2)
    check(NativeCallbackTraversal.next(order, 3, 0, true) == null)
    check(NativeCallbackTraversal.next(order, 3, 2, true) == 2)
    check(NativeCallbackTraversal.previous(order, 2, 0) == 2)
    check(NativeCallbackTraversal.previous(order, 2, 2) == 3)
    // Inserting a manual item immediately after current does not replay shuffled history.
    check(NativeCallbackTraversal.insert(order, 3, 1, 2, true, false, setOf(1), true) == listOf(2, 3, 5, 1, 0, 4))
    check(NativeCallbackTraversal.insert(order, 5, 2, 2, false, true, emptySet(), true) == listOf(2, 4, 1, 0, 3, 5, 6))
    check(NativeCallbackTraversal.insert(order, 3, 1, 2, true, false, emptySet(), false) == (0..5).toList())
    println("NativeCallbackTraversal: permutation, repeat, previous, manual priority and continuation passed")
}
