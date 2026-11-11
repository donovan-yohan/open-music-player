package com.soundq.designsystem

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.foundation.layout.size
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.unit.dp
import soundq.design.generated.imageVector

typealias SoundQIcon = soundq.design.generated.SoundQIcon
@Composable fun SoundQIcon(icon: SoundQIcon, contentDescription: String?, modifier: Modifier = Modifier, tint: Color = LocalContentColor.current) {
    Icon(if(icon==SoundQIcon.Settings)settingsVector else icon.imageVector,contentDescription,modifier.size(SoundQ.sizes.icon),tint)
}

// Repair at the handwritten visual boundary; the sealed generated release stays unchanged.
// Eight identical radial teeth, centered hub and stroke inset share the 24-unit viewport.
private val settingsVector:ImageVector by lazy {
    ImageVector.Builder("SoundQSettings",24.dp,24.dp,24f,24f).apply {
        listOf(
            "M10.1106 4.9487 L10.4024 2.9398 L13.5976 2.9398 L13.8894 4.9487 L15.6500 5.6780 L17.2769 4.4638 L19.5362 6.7231 L18.3220 8.3500 L19.0513 10.1106 L21.0602 10.4024 L21.0602 13.5976 L19.0513 13.8894 L18.3220 15.6500 L19.5362 17.2769 L17.2769 19.5362 L15.6500 18.3220 L13.8894 19.0513 L13.5976 21.0602 L10.4024 21.0602 L10.1106 19.0513 L8.3500 18.3220 L6.7231 19.5362 L4.4638 17.2769 L5.6780 15.6500 L4.9487 13.8894 L2.9398 13.5976 L2.9398 10.4024 L4.9487 10.1106 L5.6780 8.3500 L4.4638 6.7231 L6.7231 4.4638 L8.3500 5.6780 Z",
            "M9 12a3 3 0 1 0 6 0a3 3 0 1 0 -6 0Z",
        ).forEach { path ->
            addPath(PathParser().parsePathString(path).toNodes(),fill=null,stroke=SolidColor(Color.Black),
                strokeLineWidth=soundq.design.generated.SoundQComposeTokens.COMPONENT_ICON_STROKE_WIDTH,
                strokeLineCap=StrokeCap.Butt,strokeLineJoin=StrokeJoin.Miter)
        }
    }.build()
}

/** Handwritten extension authority. Never alter the sealed generated icon release. */
enum class SoundQPlayerIcon { Shuffle, Repeat, Devices }

@Composable fun SoundQIcon(icon: SoundQPlayerIcon, contentDescription: String?, modifier: Modifier = Modifier, tint: Color = LocalContentColor.current) {
    Icon(playerVectors.getValue(icon),contentDescription,modifier.size(SoundQ.sizes.icon),tint)
}

private val playerVectors:Map<SoundQPlayerIcon,ImageVector> by lazy {
    mapOf(
        SoundQPlayerIcon.Shuffle to "M3 6h3l12 12h3M18 15l3 3-3 3M3 18h3l4-4M14 10l4-4h3M18 3l3 3-3 3",
        SoundQPlayerIcon.Repeat to "M4 9V6h15M16 3l3 3-3 3M20 15v3H5M8 15l-3 3 3 3",
        SoundQPlayerIcon.Devices to "M3 4h15v11H3zM7 20h7M10 15v5M17 10h5v11h-5z",
    ).mapValues {(icon,path)->
        ImageVector.Builder("SoundQ${icon.name}",24.dp,24.dp,24f,24f).apply {
            addPath(PathParser().parsePathString(path).toNodes(),fill=null,stroke=SolidColor(Color.Black),
                strokeLineWidth=soundq.design.generated.SoundQComposeTokens.COMPONENT_ICON_STROKE_WIDTH,
                strokeLineCap=StrokeCap.Butt,strokeLineJoin=StrokeJoin.Miter)
        }.build()
    }
}
