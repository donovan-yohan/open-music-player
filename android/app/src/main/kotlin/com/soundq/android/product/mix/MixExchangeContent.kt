package com.soundq.android.product.mix

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.text.input.TextFieldValue
import com.soundq.designsystem.*

internal enum class MixExchangePage { Choose, Import, Export }

/** Presentation only. The caller owns admission, requests, clipboard and recovery. */
@Composable internal fun MixExchangeContent(
    page:MixExchangePage,
    draft:TextFieldValue,
    onDraft:(TextFieldValue)->Unit,
    savedName:String?=null,
    exportText:String?=null,
    busy:Boolean=false,
    canImport:Boolean=false,
    fieldError:String?=null,
    fieldFocus:FocusRequester?=null,
    canChooseImport:Boolean=true,
    canChooseExport:Boolean=true,
    importReadOnly:Boolean=false,
    onChooseImport:()->Unit={},
    onChooseExport:()->Unit={},
    onBack:()->Unit={},
    onImport:()->Unit={},
    onCopy:()->Unit={},
    feedback:@Composable ColumnScope.()->Unit={},
) {
    var exported by remember(exportText){mutableStateOf(TextFieldValue(exportText.orEmpty()))}
    if(page!=MixExchangePage.Choose)SoundQIconButton(SoundQIcon.Back,"Back to mix exchange",onBack,enabled=!busy)
    when(page) {
        MixExchangePage.Choose->{
            SoundQRow("Import mix","",false,onChooseImport,enabled=!busy&&canChooseImport,trailing={SoundQIcon(SoundQIcon.Arrow,null)})
            if(savedName!=null)SoundQRow("Export saved mix",savedName,false,onChooseExport,enabled=!busy&&canChooseExport,trailing={SoundQIcon(SoundQIcon.Arrow,null)})
        }
        MixExchangePage.Import,MixExchangePage.Export->{
            Text("Performance metadata only. Matching audio must already be in the recipient’s library.",style=SoundQ.typography.caption)
            if(page==MixExchangePage.Export) {
                savedName?.let {Text(it,style=SoundQ.typography.title)}
                Text("Exports the saved version, not unsaved edits.",style=SoundQ.typography.caption)
                MixJsonField(exported,{exported=it},readOnly=true)
            }else MixJsonField(draft,onDraft,readOnly=busy||importReadOnly,error=fieldError,focus=fieldFocus)
        }
    }
    Column(Modifier.fillMaxWidth(),verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium),content=feedback)
    when(page) {
        MixExchangePage.Import->SoundQButton("Import mix",onImport,enabled=canImport&&!busy)
        MixExchangePage.Export->SoundQButton("Copy JSON",onCopy,enabled=exportText!=null&&!busy)
        MixExchangePage.Choose->Unit
    }
}
