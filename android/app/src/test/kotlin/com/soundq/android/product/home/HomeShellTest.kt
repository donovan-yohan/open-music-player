package com.soundq.android.product.home

import com.soundq.android.data.home.*
import org.junit.Assert.*
import org.junit.Test

class HomeShellTest {
    @Test fun defaultLibraryNavigationAbaDisposalAndAccountRevocation() {
        var accountCurrent=true
        val shell=HomeShell {accountCurrent}
        assertEquals(HomeDestination.Library,shell.route.value.destination)
        shell.navigate(HomeDestination.Home)
        val a=shell.route.value
        assertEquals(HomeDestination.Home,a.destination);assertTrue(a.current())
        shell.navigate(HomeDestination.History);shell.navigate(HomeDestination.Home)
        assertFalse(a.current());assertTrue(shell.route.value.current())
        accountCurrent=false
        assertFalse(shell.route.value.current())
        val other=HomeShell();other.navigate(HomeDestination.Home);val retained=other.route.value
        other.close();assertFalse(retained.current());other.navigate(HomeDestination.Home);assertFalse(other.route.value.current())
    }
}
