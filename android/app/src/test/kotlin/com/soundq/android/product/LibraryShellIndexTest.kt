package com.soundq.android.product

import org.junit.Assert.assertEquals
import org.junit.Test

class LibraryShellIndexTest {
    @Test fun fixedChromeContributesNoLazyItemsAndStatusCellsAreCountedOnce() {
        for(index in listOf(0,1,12,49)) {
            assertEquals(index,libraryRowScrollIndex(index,false,false))
            assertEquals(index+1,libraryRowScrollIndex(index,true,false))
            assertEquals(index,libraryRowScrollIndex(index,false,true))
            assertEquals(index+1,libraryRowScrollIndex(index,true,true))
        }
    }
}
