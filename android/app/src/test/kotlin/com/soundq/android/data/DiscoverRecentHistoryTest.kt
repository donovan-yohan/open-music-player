package com.soundq.android.data

import com.soundq.android.data.discovery.DiscoveryHistory
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class DiscoverRecentHistoryTest {
    @Test fun boundedHistoryReopensOnlyForExactEndpointAndAccountAndPreservesRejectedBytes() {
        val dir=Files.createTempDirectory("discover-history-").toFile()
        try {
            val history=DiscoveryHistory(dir)
            repeat(25){history.add("endpoint-A","account-A","query $it")}
            assertEquals(20,history.load("endpoint-A","account-A").size)
            assertEquals("query 24",DiscoveryHistory(dir).load("endpoint-A","account-A").first())
            assertTrue(history.load("endpoint-B","account-A").isEmpty())
            assertTrue(history.load("endpoint-A","account-B").isEmpty())
            assertEquals(listOf("QUERY 24","query 23"),history.add("endpoint-A","account-A","QUERY 24").take(2))
            val file=dir.listFiles()!!.single();file.writeText("future/rejected")
            assertTrue(history.add("endpoint-A","account-A","must not overwrite").isEmpty())
            assertEquals("future/rejected",file.readText())
        } finally {dir.deleteRecursively()}
    }
}
