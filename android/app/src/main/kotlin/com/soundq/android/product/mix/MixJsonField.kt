package com.soundq.android.product.mix

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import com.soundq.designsystem.SoundQ

/** Native editor value remains presentation-owned, including selection and composition. */
@Composable internal fun MixJsonField(
    value:TextFieldValue,
    onValueChange:(TextFieldValue)->Unit,
    modifier:Modifier=Modifier,
    readOnly:Boolean=false,
    error:String?=null,
    focus:FocusRequester?=null,
) {
    Column(modifier.fillMaxWidth(),verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.small)) {
        Text("Mix JSON",style=SoundQ.typography.caption)
        OutlinedTextField(value,onValueChange,Modifier.fillMaxWidth().then(if(focus!=null)Modifier.focusRequester(focus)else Modifier).semantics {contentDescription="Mix JSON"},
            enabled=true,readOnly=readOnly,singleLine=false,minLines=5,maxLines=10,
            textStyle=SoundQ.typography.mono,shape=RectangleShape,isError=error!=null,
            keyboardOptions=KeyboardOptions(capitalization=KeyboardCapitalization.None,autoCorrectEnabled=false),
            supportingText={Text(error ?: "Maximum 256 KiB of UTF-8 metadata.")},
            colors=OutlinedTextFieldDefaults.colors(focusedBorderColor=SoundQ.colors.focus,unfocusedBorderColor=SoundQ.colors.inputBorder,
                cursorColor=SoundQ.colors.focus,errorBorderColor=SoundQ.colors.error,
                focusedTextColor=SoundQ.colors.text,unfocusedTextColor=SoundQ.colors.text,errorCursorColor=SoundQ.colors.error))
    }
}
