# Pure visual Compose API contract — provisional engineering inputs

This is an interface/composition contract, not compiled Android production components. The foundation owner implements it under the separate Android `:designsystem` module; Hotate does not edit that worktree.

## Module boundary

`:designsystem` may depend on Compose UI/Foundation, visual animation/inset/semantics primitives, generated SoundQ tokens/icons and supplied font/image resources. It **must not depend on** HTTP, accounts, navigation controllers/routes, Track DTOs, repositories, ViewModels, MediaController, Media3 service or the old Rust/JNI core. `:app` adapts feature state into these visual inputs and maps emitted intents back to navigation/ViewModels/Media3.

Pure visual means state-in/action-out. Ephemeral press/focus/gesture-follow state can live inside a remembered visual interaction object, but it cannot select tracks, mutate a queue, authenticate or perform IO.

## Typed primitives

- Use `SoundQComposeTokens`: semantic `Color`; spacing/sizing as `Dp`; font sizes **and letter spacing as `TextUnit` (`sp`)**; `FontWeight`; `CubicBezierEasing`; integer millisecond durations. No parallel hand-authored palette.
- `generated/SoundQIcons.kt` defines a closed `SoundQIcon` enum and typed `ImageVector` mapping for 29 project-owned symbols (including secure-entry Show/Hide). Feature components accept that enum, never string icon names or ad-hoc per-screen SVGs. `assets/icons/source.json` owns geometry; default stroke width references the token authority.
- Supplied normal-width font files and OFL notices are bundled locally. Engineering binds real font resources; generated family-name strings do not magically register fonts.
- Provide a typed visual theme wrapper that supplies semantic tokens and typography. Do not expose a mutable global palette or per-screen numeric spacing bags.

## Recommended public interfaces

The following Kotlin signatures express ownership; the engineering implementation can choose equivalent stable names without changing these semantics:

```kotlin
enum class ActionTone { Neutral, Primary, Secondary, Destructive }
enum class TransportVisual { Playing, Paused, Preparing, Unavailable, Failed }
enum class RevealIntent { Open, Close }

@Immutable
data class ActionVisualState(
    val enabled: Boolean = true,
    val selected: Boolean = false,
    val tone: ActionTone = ActionTone.Neutral,
)

@Composable fun SoundQIconAction(
    icon: SoundQIcon,
    accessibleName: String,
    state: ActionVisualState,
    onActivate: () -> Unit,
    modifier: Modifier = Modifier,
)

@Composable fun SoundQTextAction(
    label: String,
    state: ActionVisualState,
    onActivate: () -> Unit,
    leadingIcon: SoundQIcon? = null,
    modifier: Modifier = Modifier,
)

@Composable fun SoundQTextField(
    value: TextFieldValue,
    onValueChange: (TextFieldValue) -> Unit,
    label: String,
    errorMessage: String?,
    enabled: Boolean,
    keyboardOptions: KeyboardOptions,
    keyboardActions: KeyboardActions,
    visualTransformation: VisualTransformation,
    modifier: Modifier = Modifier,
)

@Composable fun SoundQMediaRow(
    title: String,
    subtitle: String,
    supportingText: String?,
    selected: Boolean,
    current: Boolean,
    enabled: Boolean,
    revealed: Boolean,
    onRevealIntent: (RevealIntent) -> Unit,
    onActivate: () -> Unit,
    onMore: () -> Unit,
    artwork: @Composable () -> Unit,
    revealedActions: @Composable RowScope.() -> Unit,
    modifier: Modifier = Modifier,
)

@Composable fun SoundQCompactPlayer(
    title: String,
    subtitle: String,
    transport: TransportVisual,
    progress: Float,
    onExpand: () -> Unit,
    onPrimaryAction: () -> Unit,
    onQueue: () -> Unit,
    onCancelPreparation: () -> Unit,
    artwork: @Composable () -> Unit,
    modifier: Modifier = Modifier,
)
```

Use distinct typed state models for collection tabs/navigation selection, feedback and progress. Do not overload nullable strings or raw backend status integers as visual state. Artwork uses a visual slot or decoded image state (`Loading`, `Available`, `Missing`, `Failed`), not an authenticated URL fetch owned by the component.

A label-bearing text action is still required for sign-in/registration submission, Apply, uncertain-mutation recovery and destructive removal. An icon action must always expose its accessible name and a 48dp minimum target; no tooltip-only action.

## Composition, not screen-by-screen rebuilding

Library composes `SoundQMasthead`, `SoundQTextField` (search variant), collection tabs, shared `SoundQMediaRow`, shared state feedback, `SoundQCompactPlayer` and labeled navigation. The feature supplies display strings, decoded artwork, selected/current flags and callbacks. It does not rebuild padding, typography or icon buttons.

Auth composes the same field/text-action/error-feedback primitives in a separate signed-out hierarchy. Account validation and request outcomes remain `:app` state. Full player and Queue reuse transport/icon/row/progress primitives; duplicate queue occurrences are feature-owned stable keys, not a visual component's inferred Track identity. Forms use `TextFieldValue` or equivalent to preserve composition/selection rather than replacing strings and losing IME state.

Sheets/drawers expose visible/snap/dismiss intent plus content slots. Use native platform modal/focus/Back/inset behavior. A sheet component must not construct feature navigation or install a second app-wide Back owner. The browser's motion algorithm is an exercised reference, not required Kotlin code to port literally.

## Tests expected from engineering

- Parameterized component previews and state tests for normal/pressed/focus/selected/disabled/loading/error at compact, 200% text and long/Unicode content.
- Named semantics and non-gesture alternatives; minimum target width **and** height; no dependency on a Track DTO or media/account object to render a component.
- Android IME/secure entry/selection/autofill/insets/native Back/TalkBack and reduced-animation evidence with the actual chosen stable platform stack.
- Feature tests prove callbacks are composed into the real shared media/account owners; a visual component preview is not playback/auth/backend proof.
- Input hashes are pinned from `evidence/compose-input-binding.json` or the provisional foundation archive. No mutable links into Hotate's authoring directory. Promote a new snapshot deliberately, with generated-drift checks, instead of forking the palette.

## Current evidence

Token generation, alias/type validation, tracking `sp` checks, icon geometry/export validation and deterministic drift checks have executed. The HTML reference exercises row/action/modal behavior. **These signatures and generated Compose files are not compiled or native-tested by Hotate.** Foundation shipping/build/runtime remains with Ebi's owner, without waiting for routine per-component approvals.
