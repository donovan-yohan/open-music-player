package com.soundq.android.data

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import com.soundq.android.data.trackdetails.*
import com.soundq.android.product.trackdetails.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

/** Real presentation adapter -> captured repository -> trusted fixture TLS. No native runtime. */
class W7DetailsWireTest {
    @Test fun dirtyUncertainReloadIsGetOnlyAndRequiresAnExplicitNewSaveWithFullReplacement() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply(analysisBody());repository.load(route)
            val editor=DetailsEditor();editor.observe(repository.state.value);editor.page=DetailsPage.Metadata
            val value=TextFieldValue("Personal",TextRange(2,5))
            editor.metadata[0]=value
            val action=editor.metadataAction()!!;val observed=repository.state.value.detail!!
            editor.submitted(action,observed,repository.state.value.analysis)
            val ticket=repository.claim(route,observed,action)!!
            f.reply("{}");repository.execute(ticket);editor.observe(repository.state.value)
            assertEquals(MutationOutcome.Uncertain,repository.state.value.outcome)
            assertEquals(value,editor.metadata[0]);assertTrue(editor.dirty)
            assertNull(repository.claim(route,observed,action))
            assertFalse(editor.requestDismiss(DismissDestination.Closed));editor.keepEditing()
            f.reply(detailsPage(detailsRow("Server title",true)));f.reply(analysisBody(4));repository.load(route)
            editor.observe(repository.state.value)
            assertEquals(value,editor.metadata[0]);assertEquals(MutationOutcome.Uncertain,repository.state.value.outcome)
            val requests=(1..5).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!}
            assertEquals(listOf("GET","GET","PUT","GET","GET"),requests.map {it.method})
            assertEquals("""{"title":"Personal","artist":"Ensemble","album":"Source album"}""",requests[2].body!!.utf8())
            assertEquals(5,f.server.requestCount)
            assertEquals(action,editor.metadataAction())
            repository.close(route)
            assertNull(repository.claim(route,repository.state.value.detail?:observed,action))
        }
    }
    @Test fun cancelledResetNeverClaimsAndConfirmedResetReadbackRetiresOnlyMetadataDraft() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage(detailsRow("Personal",true)));f.reply(analysisBody());repository.load(route)
            val observed=repository.state.value.detail!!
            val editor=DetailsEditor();editor.observe(repository.state.value)
            editor.metadata[0]=TextFieldValue("Unsaved");editor.correction[0]=TextFieldValue("125")
            val action=DetailsAction.Metadata(MetadataDraft())
            editor.confirmation=DetailsConfirmation("Reset metadata?","Original metadata","Confirm metadata reset",observed,action)
            editor.confirmation=null
            assertEquals(2,f.server.requestCount);assertEquals("Unsaved",editor.metadata[0].text)
            editor.submitted(action,observed,repository.state.value.analysis)
            val ticket=repository.claim(route,observed,action)!!
            f.reply("""{"track_id":7,"has_metadata_override":false,"title":null,"artist":null,"album":null}""")
            f.reply(detailsPage());repository.execute(ticket);editor.observe(repository.state.value)
            assertEquals("Original",editor.metadata[0].text);assertFalse(editor.metadataDirty)
            assertEquals("125",editor.correction[0].text);assertTrue(editor.dirty)
            assertEquals(MutationOutcome.Confirmed,repository.state.value.outcome)
        }
    }
}
