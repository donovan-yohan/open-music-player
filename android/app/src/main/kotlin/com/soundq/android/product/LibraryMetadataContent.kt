package com.soundq.android.product

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import com.soundq.designsystem.SoundQ
import com.soundq.designsystem.LocalMediaRowCompactMetadata

/** Whole facts have independent ink and natural width; analysis never receives a zero-width remainder. */
@Composable internal fun LibraryMetadataContent(fields:List<LibraryMetadataField>) {
    if(fields.isEmpty())return
    val compact=LocalMediaRowCompactMetadata.current
    val density=LocalDensity.current
    val style=if(compact)SoundQ.typography.caption.copy(lineHeight=with(density){34.dp.toSp()}) else SoundQ.typography.caption
    val host=Modifier.testTag("library-row-metadata").semantics {contentDescription=fields.joinToString(", "){it.spoken}}
    val content:@Composable (List<LibraryMetadataField>)->Unit={visible ->
        visible.forEach {field ->
            val analysis=field.kind!=LibraryMetadataKind.Duration
            val scheme=MaterialTheme.colorScheme
            // Port of client SongMetadataChips: secondary-container tempo, stable Camelot HSV wheel.
            val wheel=field.camelot
            val background=if(wheel!=null) {
                val number=wheel.dropLast(1).toInt()
                val dark=scheme.background.luminance()<0.5f
                val minor=wheel.endsWith('A')
                Color.hsv((number-1)*30f,if(dark)0.68f else 0.78f,
                    if(dark){if(minor)0.78f else 0.92f}else{if(minor)0.58f else 0.72f})
            } else scheme.secondaryContainer
            val foreground=if(wheel==null)scheme.onSecondaryContainer else {
                val luminance=background.luminance()
                if((luminance+0.05f)/0.05f>=1.05f/(luminance+0.05f))Color.Black else Color.White
            }
            // The reference list-row compact policy omits the unit, never the tempo value.
            val display=if(compact&&field.kind==LibraryMetadataKind.Tempo)field.display.removeSuffix(" BPM") else field.display
            Text(display,
                if(analysis)Modifier.width(IntrinsicSize.Max).background(background).padding(horizontal=if(compact)0.dp else 4.dp)
                else Modifier.width(IntrinsicSize.Max),
                color=if(analysis)foreground else SoundQ.colors.muted,
                style=style,maxLines=1,softWrap=false)
        }
    }
    if(compact)Column(host.fillMaxWidth()) {
        Box(Modifier.height(34.dp).fillMaxWidth(),contentAlignment=Alignment.CenterEnd) {
            content(fields.filter {it.kind==LibraryMetadataKind.Duration})
        }
        Row(Modifier.height(34.dp).fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(4.dp)) {
            content(fields.filter {it.kind!=LibraryMetadataKind.Duration})
        }
    } else Row(host,horizontalArrangement=Arrangement.spacedBy(4.dp)) {content(fields)}
}
