# Auth core — authored browser reference and implementation contract

**Status: exercised synthetic reference subset, not native authentication/persistence acceptance.** Source behavior baseline: current Flutter login/register/router at `f0611826b6c77ed9f99eb97e1e55b11032b0ca28`, not the superseded installed Views/JNI client. No account API is called. Session outcomes are deliberately controlled external fixtures.

## Entry and hierarchy

- Open `http://127.0.0.1:43187/reference/?auth=signin&next=%2Fqueue`, or choose **Session fixture** and **Auth response** in `lab.html` and Apply.
- `auth=signin|register|restore|expired`; `authResult=success|refused|network|uncertain|storage|pending`. A failure fixture fails its first explicit attempt; explicit recovery then resolves successfully. `pending` intentionally stays pending. This is a test schedule, not a retry policy or fabricated API response.
- Sign-in and registration are a separate signed-out hierarchy. No mini-player, listening navigation or enabled private-media controls behind the form. Settings' **Sign out** returns here and pauses simulated listening. This is not proof of native account retirement, Media3 stopping, storage wiping or account-scoped cache isolation.
- A nonempty safe local return is retained across registration/sign-in. External, protocol-relative, backslash, newline and sign-in/register-loop destinations fall back to Home. Reference destinations include Home, Library, Discover, Playlists, Settings, Queue and full player. Other local routes fall back to Library in this intentionally bounded reference; that is **not** a replacement router policy for Flutter/Compose.
- Native navigation, session validity and endpoint identity remain feature/controller authority. Do not copy the browser URL/mode controller into the design-system module.

## Composed visual layer versus features

`:designsystem` supplies reusable **field, secure field, label/help/error, notice, icon button, primary/secondary action, form stack, page/brand, modal and loading** visuals. It receives visual state and emits edits/actions. Typed `Color`/`Dp`/`TextUnit`/motion values and `SoundQIcon` come from generated authority.

`:app` composes sign-in/register/restore, supplies draft values and validation, owns secure-entry lifetime, request generations, navigation/next, HTTP, session persistence and account retirement. No account DTO, auth repository, endpoint, route or playback dependency enters `:designsystem`.

Recommended input vocabulary for native implementation: field label/value/helper/error/enabled; input kind and platform `KeyboardOptions`/`KeyboardActions`; secure/revealed state and `onRevealRequested`; `onValueChange`, `onFocusChanged`, `onImeAction`. Visual fields must not start validation HTTP, store passwords, navigate or own authentication. Secure field values must not become generated data-class debug output, analytics, saved-instance bundles or generic draft serialization. Actual native password-manager/autofill behavior requires separate qualification.

## Form anatomy and behavior

- Persistent external labels: Username (registration), Email, Password, Confirm password (registration). Native password controls, not a fake text rectangle. No floating-placeholder dependence.
- Angular neutral field boundary; cyan focus; explicit helper/error text, invalid semantics and error border, not color alone. Input padding binds `component.icon.padding`; minimum input/field/target metrics bind the existing `component.search.*` / `component.icon.*` aliases. No second numeric palette or typography source.
- Field label/body/helper roles use existing semantic typography; keep full 100/130/200% type scaling. Full-height scrolling signed-out content, no fixed player over the form. Native keyboard/IME avoidance must use proper WindowInsets/bring-into-view, not browser reserve sizes.
- Email: email input/autofill hint, no autocapitalization/spellcheck. Password: current-password; registration/confirmation: new-password. Registration username: username hint. Never interpret browser `autocomplete` attributes as native autofill proof.
- Each secure field has a >=48px-equivalent Show/Hide icon target with an explicit accessible name and pressed state. Reveal changes the actual input type without losing selection or caret; mask on hierarchy change/background. Repeated actions are icon-led; primary submit and error recovery retain clear words.
- Hardware Enter follows next-field order then one submit owner on the last field. Composition suppresses premature submission. The test exercises DOM events, **not** Android IME composition or actual software-keyboard actions.
- Validation: explicit empty email/password; baseline-compatible email shape; password at least eight characters; registration username 3–50 characters; confirmation required and equal. This is **not** a claim of full server policy/Unicode-byte parity. Server refusals remain explicit.
- Invalid submit focuses first invalid field. Safe email/username drafts survive refusal or mode changes; passwords are ephemeral and cleared when leaving the auth hierarchy/signing out/backgrounding. Nothing is saved to localStorage, indexedDB, receipts or test logs.

## States and outcomes

| State | Visible behavior | Feature/controller obligation |
|---|---|---|
| Idle / editing | Fields, primary sign-in/create action, explicit alternative mode | No request on editing; no hidden account mutation |
| Validation error | Associated helper/error; first invalid field focused | Preserve edits; distinguish local validation from server refusal |
| Pending | Honest progress, inputs/submit locked; no duplicate submit | One operation generation; delayed completion cannot navigate a retired view |
| Refused | Clear refusal, retained drafts, explicit retry | Do not claim account/session success |
| Network failure | Clear connection feedback, retained drafts, explicit retry | No automatic mutation replay |
| Unconfirmed registration | Primary **Sign in to check** above locked submitted fields; creation action absent | Do not auto-recreate the account; sign-in is a separate user action |
| Accepted but storage failed | Primary **Retry saving session** above locked masked fields; no shell entry | Retry persistence of accepted session, not the sign-in request; native durable ACK still required |
| Restoring | Separate session-check status | Native secure storage/expiry/refresh/account fences remain authoritative |
| Restore error | Retry restore or sign in instead | No private shell from failed/unknown session |
| Expired | Explicit reason and sign-in form; safe destination retained | Fence stale media/account callbacks |
| Reference success | Known destination opened once | Browser state only; no decoded audio, real auth or secure persistence proof |
| Sign out / retired view | Signed-out hierarchy, cleared auth drafts, synthetic playback paused | Native service/controller/cache/account cleanup remains unverified |

Back from pending registration retires that view's completion and warns that creation may still complete, preserving email but clearing secrets. It does not claim remote cancellation. No unavailable reset-password/delete-account operation is invented.

## Evidence

Run `node scripts/auth-tests.mjs` against the existing owned CDP browser and loopback server. Receipt: `evidence/core/auth-tests.json`; inspected captures: `captures/core/`.

The receipt enumerates 16 grouped checks and 23 phone captures. It includes actual pointer/hardware-keyboard form interactions, validation focus, secure reveal/selection, sign-in -> Queue, safe local next refusal, registration correction, retired pending completion, refusal/network explicit recovery, uncertain registration, storage retry, restore/expiry, DOM composition/visibility-event guards, settings sign-out, external fixture controls, and 360/412/480 widths with compact/short/100/130/200% geometry checks.

Native compilation, actual IME/password-manager/autofill/TalkBack, system Back/insets, process death, secure credential persistence, endpoint/account retirement and Media3/system acceptance are **not tested here**. Refer to `components/COMPONENTS.md`, `components/COMPOSE_VISUAL_API.md`, `components/MOTION.md` and the explicit W01/W02/M01–M09 gaps in coverage.
