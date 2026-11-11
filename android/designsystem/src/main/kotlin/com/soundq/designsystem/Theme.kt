package com.soundq.designsystem

import androidx.compose.runtime.*
import androidx.compose.material3.*
import androidx.compose.foundation.isSystemInDarkTheme
import soundq.design.generated.SoundQAppearance
import soundq.design.generated.SoundQModeColors
import soundq.design.generated.SoundQAppearanceMapping
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import soundq.design.generated.SoundQComposeTokens as T

@Immutable
data class SoundQColors(val roles: SoundQModeColors) {
    val background: Color get() = roles.semantic_color_background
    val surface: Color get() = roles.semantic_color_surface
    val raised: Color get() = roles.semantic_color_raised
    val text: Color get() = roles.semantic_color_text
    val muted: Color get() = roles.semantic_color_text_muted
    val primary: Color get() = roles.semantic_color_primary
    val onPrimary: Color get() = roles.component_button_primary_text
    val border: Color get() = roles.semantic_color_border
    val inputBorder: Color get() = roles.semantic_color_border_input
    val focus: Color get() = roles.semantic_color_focus
    val error: Color get() = roles.semantic_color_error
    val disabled: Color get() = roles.semantic_color_disabled_text
    val disabledSurface: Color get() = roles.semantic_color_disabled_background
    val secondary: Color get() = roles.semantic_color_secondary
    val scrim: Color get() = roles.w9_color_sheet_scrim
    val reveal: Color get() = roles.w9_color_row_reveal_background
    val onReveal: Color get() = roles.w9_color_row_reveal_text
    val waveform: Color get() = roles.w9_color_waveform_base
    val beat: Color get() = roles.w9_color_waveform_beat
    val cue: Color get() = roles.w9_color_waveform_cue
    val origin: Color get() = roles.w9_color_waveform_origin
    val playhead: Color get() = roles.w9_color_waveform_playhead
    val waveSelection: Color get() = roles.w9_color_waveform_selection
    val progressTrack: Color get() = roles.semantic_color_progress_track
    val player: Color get() = roles.w9_color_compact_player_background
    val sheet: Color get() = roles.w9_color_sheet_background
}
fun appearanceColors(choice:SoundQAppearance,systemDark:Boolean):SoundQColors = SoundQColors(SoundQAppearanceMapping.resolve(choice,systemDark))
private val LocalColors = staticCompositionLocalOf { appearanceColors(SoundQAppearance.System,false) }
object SoundQSpacing {
    val small: Dp = T.SEMANTIC_DIMENSION_RHYTHM
    val medium: Dp = T.COMPONENT_ROW_GAP
    val large: Dp = T.COMPONENT_PLAYER_GAP
    val gutter: Dp = T.SEMANTIC_DIMENSION_PAGE_GUTTER
}
object SoundQSizes {
    val target: Dp = T.SEMANTIC_DIMENSION_TARGET_MIN
    val icon: Dp = T.SEMANTIC_DIMENSION_ICON
    val border: Dp = T.SEMANTIC_DIMENSION_BORDER
    val focus: Dp = T.SEMANTIC_DIMENSION_FOCUS_WIDTH
    val row: Dp = T.COMPONENT_ROW_MIN_HEIGHT
    val mediaRow: Dp = 72.dp
    val appMax: Dp = T.SEMANTIC_DIMENSION_APP_MAX
}
object SoundQTypography {
    private val display = FontFamily(Font(R.font.space_regular, T.SEMANTIC_FONT_WEIGHT_REGULAR), Font(R.font.space_semibold, T.SEMANTIC_FONT_WEIGHT_SEMIBOLD))
    private val technical = FontFamily(Font(R.font.plex_regular))
    val body = TextStyle(fontFamily = display, fontSize = T.SEMANTIC_FONT_SIZE_BODY, lineHeight = T.SEMANTIC_FONT_SIZE_BODY * T.SEMANTIC_LINE_HEIGHT_BODY)
    val heading = body.copy(fontSize = T.SEMANTIC_FONT_SIZE_H1, lineHeight = T.SEMANTIC_FONT_SIZE_H1 * T.SEMANTIC_LINE_HEIGHT_HEADING, letterSpacing = T.SEMANTIC_LETTER_SPACING_HEADING, fontWeight = T.SEMANTIC_FONT_WEIGHT_SEMIBOLD)
    val title = body.copy(fontSize = T.SEMANTIC_FONT_SIZE_TITLE, lineHeight = T.SEMANTIC_FONT_SIZE_TITLE * T.SEMANTIC_LINE_HEIGHT_TITLE, fontWeight = T.SEMANTIC_FONT_WEIGHT_SEMIBOLD)
    val caption = body.copy(fontSize = T.SEMANTIC_FONT_SIZE_ARTIST, lineHeight = T.SEMANTIC_FONT_SIZE_ARTIST * T.SEMANTIC_LINE_HEIGHT_BODY)
    val mono = body.copy(fontFamily = technical, fontSize = T.SEMANTIC_FONT_SIZE_MONO, lineHeight = T.SEMANTIC_FONT_SIZE_MONO * T.SEMANTIC_LINE_HEIGHT_BODY, letterSpacing = T.SEMANTIC_LETTER_SPACING_MONO)
}
private val LocalMotion = staticCompositionLocalOf { SoundQMotion() }
object SoundQ {
    val colors: SoundQColors @Composable get() = LocalColors.current
    val spacing get() = SoundQSpacing
    val sizes get() = SoundQSizes
    val typography get() = SoundQTypography
    val motion: SoundQMotion @Composable get() = LocalMotion.current
}

/** Complete Material host mapping. No platform/dynamic/default accent roles. */
fun appearanceColorScheme(c:SoundQColors,dark:Boolean):ColorScheme {
    val roles = if(dark) darkColorScheme() else lightColorScheme()
    return roles.copy(
        primary=c.primary,onPrimary=c.onPrimary,primaryContainer=c.raised,onPrimaryContainer=c.text,
        inversePrimary=c.primary,secondary=c.secondary,onSecondary=c.onReveal,
        secondaryContainer=c.surface,onSecondaryContainer=c.text,tertiary=c.focus,onTertiary=c.onReveal,
        tertiaryContainer=c.raised,onTertiaryContainer=c.text,background=c.background,onBackground=c.text,
        surface=c.surface,onSurface=c.text,surfaceVariant=c.raised,onSurfaceVariant=c.muted,
        surfaceTint=c.surface,inverseSurface=c.text,inverseOnSurface=c.background,
        error=c.error,onError=c.background,errorContainer=c.surface,onErrorContainer=c.error,
        outline=c.inputBorder,outlineVariant=c.border,scrim=c.scrim,
        surfaceBright=c.raised,surfaceDim=c.background,surfaceContainer=c.surface,
        surfaceContainerHigh=c.raised,surfaceContainerHighest=c.raised,
        surfaceContainerLow=c.surface,surfaceContainerLowest=c.background,
        primaryFixed=c.primary,primaryFixedDim=c.primary,onPrimaryFixed=c.onPrimary,onPrimaryFixedVariant=c.onPrimary,
        secondaryFixed=c.secondary,secondaryFixedDim=c.secondary,onSecondaryFixed=c.onReveal,onSecondaryFixedVariant=c.onReveal,
        tertiaryFixed=c.focus,tertiaryFixedDim=c.focus,onTertiaryFixed=c.onReveal,onTertiaryFixedVariant=c.onReveal,
    )
}
@Composable fun SoundQTheme(reducedMotion:Boolean=false,appearance:SoundQAppearance=SoundQAppearance.System,content:@Composable ()->Unit) {
    val systemDark=isSystemInDarkTheme()
    val dark=appearance==SoundQAppearance.Dark||(appearance==SoundQAppearance.System&&systemDark)
    val c=remember(appearance,systemDark){appearanceColors(appearance,systemDark)}
    CompositionLocalProvider(LocalColors provides c,LocalMotion provides remember(reducedMotion){SoundQMotion(reducedMotion)}) {
        MaterialTheme(
            colorScheme=remember(c,dark){appearanceColorScheme(c,dark)},
            typography=Typography(bodyLarge=SoundQ.typography.body,bodyMedium=SoundQ.typography.body,labelLarge=SoundQ.typography.body,titleLarge=SoundQ.typography.heading),
            content=content,
        )
    }
}
