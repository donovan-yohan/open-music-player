package com.soundq.android.playback

import org.junit.Assert.*
import org.junit.Test

class QueueReorderCommandsTest {
    @Test fun changedAndReturnedOrderCannotReviveCapturedCommand() {
        val controller=Any();val order=listOf("occ-1","occ-2","occ-3")
        var snapshot:ReorderSnapshot<Any>?=ReorderSnapshot(controller,1,order)
        val moves=mutableListOf<Pair<Int,Int>>()
        val commands=QueueReorderCommands({snapshot}) {_,from,to->moves.add(from to to)}
        val route=commands.capture {true}!!
        snapshot=ReorderSnapshot(controller,2,order.reversed())
        assertFalse(route.move("occ-1",order,2))
        snapshot=ReorderSnapshot(controller,3,order)
        assertFalse(route.move("occ-1",order,2));assertTrue(moves.isEmpty())
    }
    @Test fun routeCloseRefusesEvenWhenIdsAreUnchanged() {
        val snapshot=ReorderSnapshot(Any(),1,listOf("a","b"))
        var calls=0;val route=QueueReorderCommands({snapshot}) {_,_,_->calls++}.capture {true}!!
        route.close();assertFalse(route.move("a",snapshot.order,1));assertEquals(0,calls)
    }
    @Test fun capturedAccountCapabilityRefusesSameIdAbaAndConnectionReplacement() {
        val session=com.soundq.android.data.AccountSession(com.soundq.android.data.ApiEndpoint.parse("https://fixture.invalid/api/v1"),com.soundq.android.data.MemoryStore())
        session.accept(session.beginIntent(),com.soundq.android.data.SecretTokens("a","r","A"))
        val scope=session.capture()!!
        var snapshot:ReorderSnapshot<Any>?=ReorderSnapshot(Any(),1,listOf("a","b"))
        var calls=0
        val commands=QueueReorderCommands({snapshot}) {_,_,_->calls++}
        val route=commands.capture {session.current(scope)}!!
        session.accept(session.beginIntent(),com.soundq.android.data.SecretTokens("b","r","B"))
        session.accept(session.beginIntent(),com.soundq.android.data.SecretTokens("c","r","A"))
        assertFalse(route.move("a",snapshot!!.order,1))
        val replacement=commands.capture {true}!!
        snapshot=ReorderSnapshot(Any(),1,listOf("a","b"))
        assertFalse(replacement.move("a",snapshot.order,1));assertEquals(0,calls)
    }
    @Test fun originalOrderBoundaryAndRepeatedCompletionAreRefused() {
        val snapshot=ReorderSnapshot(Any(),1,listOf("a","b","c"))
        var calls=0;val commands=QueueReorderCommands({snapshot}) {_,_,_->calls++}
        val route=commands.capture {true}!!
        assertFalse(route.move("a",snapshot.order.reversed(),2))
        assertFalse(route.move("a",snapshot.order,-1));assertFalse(route.move("a",snapshot.order,3))
        assertTrue(route.move("a",snapshot.order,2));assertFalse(route.move("a",snapshot.order,2));assertEquals(1,calls)
    }
    @Test fun currentValidatedOccurrenceUsesInsertionCommand() {
        val snapshot=ReorderSnapshot(Any(),1,listOf("duplicate-1","duplicate-2","other"))
        val moves=mutableListOf<Pair<Int,Int>>()
        val route=QueueReorderCommands({snapshot}) {_,f,t->moves.add(f to t)}.capture {true}!!
        assertTrue(route.move("duplicate-2",snapshot.order,2));assertEquals(listOf(1 to 2),moves)
    }
}
