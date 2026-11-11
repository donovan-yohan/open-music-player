package com.soundq.android.data

import com.soundq.android.data.acquisition.IntakeReceipts
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class ImportTargetJournalTest {
    @Test fun malformedOptionalTargetRefusesRecoveryAndNeverRewritesRejectedBytes() {
        val dir=Files.createTempDirectory("target-journal-validation").toFile()
        try {
            val file=dir.resolve("journal.json")
            val journal=IntakeReceipts(file)
            journal.begin("https://fixture.invalid/api/v1","A","source",sessionId="123e4567-e89b-12d3-a456-426614174010",candidateId="candidate-1",playlistId=41)
            val original=Json.parseToJsonElement(file.readText()).jsonObject
            val owners=original.getValue("owners").jsonObject
            val owner=owners.keys.single()
            val row=owners.getValue(owner).jsonArray.single().jsonObject
            for(value in listOf(JsonNull,JsonPrimitive(0),JsonPrimitive(-1),JsonPrimitive("41"),JsonPrimitive(true),buildJsonObject {},buildJsonArray {})) {
                val invalidRow=JsonObject(row+("playlistId" to value))
                val invalidOwners=JsonObject(mapOf(owner to JsonArray(listOf(invalidRow))))
                file.writeText(JsonObject(original+("owners" to invalidOwners)).toString())
                val bytes=file.readBytes()
                val rejected=IntakeReceipts(file)
                assertTrue("Malformed target $value must not become a different destination",runCatching {rejected.entries("https://fixture.invalid/api/v1","A")}.isFailure)
                assertTrue(runCatching {rejected.begin("https://fixture.invalid/api/v1","A","source")}.isFailure)
                assertArrayEquals(bytes,file.readBytes())
            }
        } finally {dir.deleteRecursively()}
    }
}
