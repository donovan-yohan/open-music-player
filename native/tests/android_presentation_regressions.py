#!/usr/bin/env python3
"""Native Android presentation gate, including independent causal mutations.

No emulator/service/backend. Builds private source copies with isolated Gradle
outputs; tests production Activity/Rows/style under Robolectric native graphics.
The registered Library runner invokes this by default in its compiled lane.
"""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET

TEST_CLASS = 'com.soundq.nativepreview.AndroidPresentationTest'
TESTS = {
    'normalAllocationBeforeAndAfterDock', 'compactAllocationBeforeAndAfterDock',
    'rowContentGridAndSeparateCallbacks', 'squareNativeInteractionRasterAllStates',
    'normalEmptyRecoveryBeforeAndAfterDock', 'compactEmptyRecoveryBeforeAndAfterDock',
    'realPlayNativePrimaryRasterAllStates',
    'compactKeyboardConstrainedRecoveryFamily', 'normalKeyboardConstrainedRecoveryFamily',
    'compactPostRefusalCorrectionAllocation', 'attachedNestedScrollOwnership',
}
PACKAGE = Path('app/src/main/java/com/soundq/nativepreview')
OWNER_ENV = 'SOUNDQ_PRESENTATION_INVOCATION'
WAIT_SECONDS = 300


def owned_processes(owner):
    """POSIX ps environment token, not command/path or shared Gradle matching.

    macOS and Linux ps expose inherited environments with e. Keep only the
    private token's rows; never retain other processes' environments.
    lstart binds recorded PIDs to a process generation before signalling.
    Refuse unavailable enumeration rather than claiming an empty ownership set.
    """
    canary = uuid.uuid4().hex
    marker = 'SOUNDQ_PRESENTATION_ENUMERATION=' + canary
    result = subprocess.run(['ps', 'axeww', '-o',
        'pid=,ppid=,pgid=,lstart=,stat=,command='],
        env=dict(os.environ, SOUNDQ_PRESENTATION_ENUMERATION=canary),
        capture_output=True, text=True, timeout=2, check=True)
    rows = []
    visible = False
    token = OWNER_ENV + '=' + owner
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        fields = line.split(None, 9)
        try:
            if len(fields) != 10:
                raise ValueError('Incomplete process row')
            row = {'pid': int(fields[0]), 'ppid': int(fields[1]),
                'pgid': int(fields[2]), 'started': ' '.join(fields[3:8]),
                'state': fields[8], 'executable': fields[9].split()[0]}
        except (ValueError, IndexError) as error:
            raise RuntimeError('Unusable process enumeration') from error
        words = fields[9].split()
        visible = visible or marker in words
        if token in words:
            rows.append(row)
    if not visible:
        raise RuntimeError('Process environment visibility unavailable')
    return rows


def recorded_processes(identities):
    """Independently check recorded generations without environment visibility.

    This is an absence check, never permission to signal an unverified process.
    """
    result = subprocess.run(['ps', 'axww', '-o', 'pid=,lstart=,stat='],
        capture_output=True, text=True, timeout=2, check=True)
    generations = {}
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        fields = line.split()
        try:
            if len(fields) != 7:
                raise ValueError('Incomplete structural process row')
            generations[int(fields[0])] = (' '.join(fields[1:6]), fields[6])
        except ValueError as error:
            raise RuntimeError('Unusable structural process enumeration') from error
    if os.getpid() not in generations:
        raise RuntimeError('Structural process visibility unavailable')
    return [dict(row, state=generations[row['pid']][1]) for row in identities
        if row['pid'] in generations and generations[row['pid']][0] == row['started']]


def drain_owned(proc, owner, state):
    """Synchronous bounded drain of this invocation, including setsid children.

    TERM children before parents so ordinary parents can reap; repeat discovery
    through teardown, then escalate only exact still-owned process identities.
    No global Gradle stop, cache deletion, or process-group assumption.
    """
    deadline = time.monotonic() + 8
    soft_deadline = time.monotonic() + 4
    seen = {(r['pid'], r['started']): r for r in state['identities']}
    while True:
        proc.poll()  # Reap our launcher, including after external interruption.
        rows = owned_processes(owner)
        for row in rows:
            seen[(row['pid'], row['started'])] = row
        state['identities'] = list(seen.values())
        confirmed = {(row['pid'], row['started']) for row in rows}
        hidden = [row for row in recorded_processes(state['identities'])
            if (row['pid'], row['started']) not in confirmed]
        if hidden:
            state['remaining'] = hidden
            if any(not row['state'].startswith('Z') for row in hidden):
                raise RuntimeError('Recorded process ownership visibility unavailable')
            # Exited children no longer expose environments while their parent
            # reaps them. Never signal from this structural-only observation.
            if time.monotonic() >= deadline:
                raise RuntimeError('Recorded process reaping deadline exceeded')
            if not rows:
                time.sleep(.05)
                continue
        if not rows:
            proc.wait(timeout=max(.01, deadline - time.monotonic()))
            state['released'] = True
            state['remaining'] = []
            return
        state['remaining'] = rows
        if time.monotonic() >= deadline:
            raise RuntimeError('Invocation cleanup deadline exceeded')
        parents = {row['ppid'] for row in rows}
        leaves = [row for row in rows if row['pid'] not in parents]
        for row in leaves or rows:
            current = owned_processes(owner)
            if any(r['pid'] == row['pid'] and r['started'] == row['started'] for r in current):
                try:
                    os.kill(row['pid'], signal.SIGTERM if time.monotonic() < soft_deadline else signal.SIGKILL)
                except ProcessLookupError:
                    pass
        time.sleep(.05)


def run_invocation(argv, project, env, log, work):
    owner = uuid.uuid4().hex
    env = dict(env, **{OWNER_ENV: owner})
    state = {'owner': owner, 'released': False, 'identities': [], 'remaining': None}
    primary = None
    proc = subprocess.Popen(argv, cwd=project, env=env, stdout=log,
        stderr=subprocess.STDOUT, start_new_session=True)
    try:
        seen = {}
        def observe():
            for row in owned_processes(owner):
                seen[(row['pid'], row['started'])] = row
            state['identities'] = list(seen.values())
        observe()
        if not any(row['pid'] == proc.pid for row in state['identities']) and proc.poll() is None:
            raise RuntimeError('Live launcher ownership unavailable')
        (work / 'process.json').write_text(json.dumps({'pid': proc.pid,
            'pgid': proc.pid, 'owner': owner}) + '\n')
        deadline = time.monotonic() + WAIT_SECONDS
        while True:
            observe()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(argv, WAIT_SECONDS)
            try:
                proc.wait(timeout=min(.25, remaining))
                break
            except subprocess.TimeoutExpired:
                if time.monotonic() >= deadline:
                    raise
    except BaseException as error:
        primary = error
        raise
    finally:
        try:
            drain_owned(proc, owner, state)
        except BaseException as error:
            state['cleanup_error'] = type(error).__name__ + ': ' + str(error)
            if primary is None:
                primary = error
                raise
            primary.add_note('Cleanup failed: ' + state['cleanup_error'])
        finally:
            try:
                (work / 'release.json').write_text(json.dumps(state, indent=2) + '\n')
            except BaseException as error:
                if primary is None:
                    raise
                primary.add_note('Release receipt failed: ' + repr(error))
    return proc.returncode


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Presentation mutation anchor must occur exactly once: ' + old)
    return text.replace(old, new, 1)


def mutate(project, variant):
    activity = project / PACKAGE / 'MainActivity.kt'
    style = project / PACKAGE / 'SoundQViews.kt'
    if variant == 'short-allocation':
        text = activity.read_text()
        text = replace_once(text,
            'library.addView(BoundedScroll(this,0.32f).apply { addView(tools) },\n            if(shortHeight) LinearLayout.LayoutParams(-1,0,1f) else LinearLayout.LayoutParams(-1,-2))',
            'library.addView(BoundedScroll(this,0.32f).apply { addView(tools) })')
        text = replace_once(text, 'LinearLayout.LayoutParams(-1,0,if(shortHeight) 2f else 1f)', 'LinearLayout.LayoutParams(-1,0,1f)')
        text = replace_once(text, 'BoundedScroll(this,if(shortHeight) 0.18f else 0.42f)', 'BoundedScroll(this,0.42f)')
        text = replace_once(text,
            'root.addView(LinearLayout(this).apply {\n            orientation = LinearLayout.HORIZONTAL; background = style.panel(style.background)\n            listOf(libraryNavigation,queueNavigation).forEach { addView(it,LinearLayout.LayoutParams(0,-2,1f)) }\n        })',
            'root.addView(actions(libraryNavigation,queueNavigation).apply { background = style.panel(style.background) })')
        activity.write_text(text)
    elif variant == 'nested-scroll-owner':
        activity.write_text(replace_once(activity.read_text(),
            'init { isNestedScrollingEnabled = true }',
            'init { isNestedScrollingEnabled = false }'))
    elif variant == 'refusal-correction-allocation':
        text = activity.read_text()
        activity.write_text(replace_once(text,
            'val constrained = library.visibility != View.GONE && (tools < cell ||\n                    (dock.visibility != View.GONE && dock.measuredHeight < dockCell))',
            'val constrained = available < cell * 3'))
    elif variant == 'ime-shell-allocation':
        text = activity.read_text()
        activity.write_text(replace_once(text,
            'maxOf(available, measuredChrome + minimumLibrary)',
            'if(resources.configuration.fontScale > 1.3f) available else maxOf(available, measuredChrome + minimumLibrary)'))
    elif variant == 'empty-outside-tools':
        text = activity.read_text()
        activity.write_text(replace_once(text, 'tools.addView(empty)', 'library.addView(empty)'))
    elif variant == 'play-orange-tint':
        text = activity.read_text()
        activity.write_text(replace_once(text,
            'play.background = style.primaryInteraction();',
            'play.background = style.interaction(); play.backgroundTintList = ColorStateList.valueOf(style.orange);'))
    elif variant == 'row-layout-params':
        activity.write_text(replace_once(activity.read_text(), 'layoutParams = RecyclerView.LayoutParams(-1,-2); ', ''))
    elif variant == 'interaction-radius':
        text = style.read_text()
        for old, new in [
            ('panel(if(selected) raised else surface,cyan)', 'panel(if(selected) raised else surface,cyan,4)'),
            ('panel(raised,cyan)', 'panel(raised,cyan,4)'),
            ('panel(if(selected) raised else background,if(selected) orange else outline)', 'panel(if(selected) raised else background,if(selected) orange else outline,4)'),
        ]:
            text = replace_once(text, old, new)
        style.write_text(text)


def inventory(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob('*')) if p.is_file() and not any(
                x in {'build', '.gradle', '.cxx'} for x in p.relative_to(root).parts)}


def auth_presentation(root, output):
    variant = os.environ.get('SOUNDQ_AUTH_PRESENTATION_VARIANT', 'green')
    result = _auth_presentation_variant(root, output, variant)
    if variant == 'green' and result['passed']:
        result['mutations'] = {name: _auth_presentation_variant(root, output / name, name)
            for name in ('auth-mode-copy', 'auth-persistent-labels', 'auth-feedback-scope')}
        result['passed'] = all(item['passed'] for item in result['mutations'].values())
        (output/'receipt.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


def _auth_presentation_variant(root, output, variant):
    output.mkdir(parents=True,exist_ok=False)
    gradle=shutil.which('gradle')
    if not gradle:raise RuntimeError('Existing Gradle installation required')
    if variant not in {'green','auth-cell-minimum-reverted','auth-mode-copy','auth-persistent-labels','auth-feedback-scope'}:raise ValueError('unknown auth presentation variant')
    project=output/'project'
    shutil.copytree(root/'native/android',project,ignore=shutil.ignore_patterns('build','.gradle','.cxx','.kotlin','local.properties'))
    if variant=='auth-cell-minimum-reverted':
        activity=project/PACKAGE/'MainActivity.kt'
        text=activity.read_text();start=text.index('                if(authScroll.visibility != View.GONE && library.visibility == View.GONE) {');end=text.index('                val cell = listOf(query',start)
        activity.write_text(text[:start]+text[end:])
    if variant in {'auth-mode-copy','auth-persistent-labels','auth-feedback-scope'}:
        activity=project/PACKAGE/'MainActivity.kt';text=activity.read_text()
        if variant=='auth-mode-copy':
            text=replace_once(text,'authInstruction.text=if(registration) "Create an account on your music server." else "Sign in to your music server."','authInstruction.text="Sign in to your music server."')
        elif variant=='auth-persistent-labels':
            start=text.index('        for(field in listOf(username,email,password,confirmation)) {')
            end=text.index('        authFeedback =',start)
            text=replace_once(text,text[start:end],'        login.addView(username);login.addView(email);login.addView(password);login.addView(confirmation)\n')
        else:
            text=replace_once(text,'if(!authenticated) uiError = null\n        else if(error != null)','if(error != null)')
            text=replace_once(text,'status.visibility = if(authenticated) View.VISIBLE else View.GONE\n        val scopedMessage = if(authenticated) message else ""','status.visibility = View.VISIBLE\n        val scopedMessage = message')
        activity.write_text(text)
    inputs=inventory(project);(output/'source-inputs.json').write_text(json.dumps(inputs,indent=2)+'\n')
    argv=[gradle,'--no-daemon','--max-workers=2','-Dorg.gradle.jvmargs=-Xmx1500m -XX:ActiveProcessorCount=2','-Pkotlin.compiler.execution.strategy=in-process',*shlex.split(os.environ.get('SOUNDQ_PRESENTATION_GRADLE_ARGS','')),':app:testDebugUnitTest','--tests','com.soundq.nativepreview.RegistrationPresentationTest']
    (output/'command.json').write_text(json.dumps(dict(argv=argv,TMPDIR=os.environ.get('TMPDIR')),indent=2)+'\n')
    with (output/'gradle.log').open('w') as log:code=run_invocation(argv,project,dict(os.environ,JAVA_TOOL_OPTIONS='-XX:ActiveProcessorCount=2'),log,output)
    cases=[]
    for p in (project/'app/build/test-results/testDebugUnitTest').glob('TEST-*.xml'):
        for c in ET.parse(p).getroot().findall('testcase'):cases.append(dict(name=c.attrib['name'],test_class=c.attrib['classname'],skipped=c.find('skipped') is not None,failures=[x.attrib.get('message','') for x in c.findall('failure')],errors=[x.attrib.get('message','') for x in c.findall('error')]))
    expected={
        'normalAuthFormErrorsPendingAndKeyboard','enlargedCompactAuthFormErrorsPendingAndKeyboard',
        'modeInstructionFollowsActualForm','enlargedCompactModeInstructionFollowsActualForm','normalPopulatedLabelsRetainSecureNativeEditing',
        'enlargedCompactPopulatedLabelsRetainSecureNativeEditing',
        'normalAuthScopedFeedbackAndAuthenticatedEmptyTransition',
        'enlargedCompactAuthScopedFeedbackAndAuthenticatedEmptyTransition',
    }
    inventory_ok=len(cases)==len(expected) and {c['name'] for c in cases}==expected and not any(c['skipped'] or c['errors'] or c['test_class']!='com.soundq.nativepreview.RegistrationPresentationTest' for c in cases)
    failed={c['name']:c['failures'] for c in cases if c['failures']}
    witnesses={
        'auth-mode-copy': ({'modeInstructionFollowsActualForm','enlargedCompactModeInstructionFollowsActualForm'},'REG-MODE correct instruction for REGISTER'),
        'auth-persistent-labels': ({'normalPopulatedLabelsRetainSecureNativeEditing','enlargedCompactPopulatedLabelsRetainSecureNativeEditing','normalAuthFormErrorsPendingAndKeyboard','enlargedCompactAuthFormErrorsPendingAndKeyboard'},'REG-LABELS'),
        'auth-feedback-scope': ({'normalAuthScopedFeedbackAndAuthenticatedEmptyTransition','enlargedCompactAuthScopedFeedbackAndAuthenticatedEmptyTransition'},'REG-FEEDBACK empty auth-only status'),
        'auth-cell-minimum-reverted': ({'enlargedCompactAuthFormErrorsPendingAndKeyboard'},'ancestor admits complete cell'),
    }
    passed=inventory_ok and code==0 and not failed
    if variant!='green':
        names,message=witnesses[variant]
        passed=inventory_ok and code!=0 and set(failed)==names and all(any(message in x for x in failed[name]) for name in names)
        if variant=='auth-cell-minimum-reverted':
            # The retained full-cell mutation now also reaches the new real
            # confirmed-refusal case; do not drop that mandatory GREEN coverage.
            additional='enlargedCompactAuthScopedFeedbackAndAuthenticatedEmptyTransition'
            passed=inventory_ok and code!=0 and set(failed)==names|{additional} and all(any(message in x for x in failed[name]) for name in names) and all('REG-FEEDBACK refused 311 full height' in x for x in failed[additional])
    receipt=dict(passed=passed,variant=variant,exit_code=code,cases=cases,inventory_admitted=inventory_ok,boundary='real native Activity controls; no service/JNI/device')
    (output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');return receipt


def run(root, output):
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    gradle = shutil.which('gradle')
    if not gradle:
        raise RuntimeError('Existing Gradle installation required for Android presentation')
    expected = {
        'green': None,
        'nested-scroll-owner': ('attachedNestedScrollOwnership', 'routing: child consumes native vertical drag'),
        'short-allocation': ('compactAllocationBeforeAndAfterDock', 'allocation compact=true selected=true: positive list viewport'),
        'row-layout-params': ('rowContentGridAndSeparateCallbacks', 'grid: row spans RecyclerView content width'),
        'interaction-radius': ('squareNativeInteractionRasterAllStates', 'shape selected=false state=rest'),
        'empty-outside-tools': ('compactEmptyRecoveryBeforeAndAfterDock', 'recovery compact=true selected=true state=emptyLiked/query: complete height'),
        'play-orange-tint': ('realPlayNativePrimaryRasterAllStates', 'primary state=focus square state stroke'),
        'ime-shell-allocation': ('compactKeyboardConstrainedRecoveryFamily', 'keyboard content=311 compact=true selected=true state=populated/query: ancestor admits complete cell'),
        'refusal-correction-allocation': ('compactPostRefusalCorrectionAllocation', 'correction content=1057 selected=true state=refusal/query: ancestor admits complete native cell'),
    }
    receipt = {'passed': False, 'boundary': 'real production Activity with refused bind; native Android layout and Skia; no service/JNI/device', 'variants': {}}
    primary = None
    try:
        for variant, witness in expected.items():
            work = output / variant
            # Refuse stale outputs, including compiled classes and old XML.
            work.mkdir(exist_ok=False)
            project = work / 'project'
            shutil.copytree(root / 'native/android', project,
                ignore=shutil.ignore_patterns('build', '.gradle', '.cxx', 'local.properties'))
            mutate(project, variant)
            inputs = inventory(project)
            (work / 'source-inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
            # Historical geometry mutations retain their original case inventory;
            # the attached pointer invariant is causal only for its own repair.
            variant_tests = TESTS if variant in {'green', 'nested-scroll-owner'} else TESTS - {'attachedNestedScrollOwnership'}
            argv = [gradle, '--no-daemon', '--max-workers=2',
                '-Dorg.gradle.jvmargs=-Xmx1500m -XX:ActiveProcessorCount=2',
                '-Pkotlin.compiler.execution.strategy=in-process',
                *shlex.split(os.environ.get('SOUNDQ_PRESENTATION_GRADLE_ARGS', '')),
                ':app:testDebugUnitTest', *[arg for name in sorted(variant_tests) for arg in ('--tests', TEST_CLASS + '.' + name)]]
            (work / 'command.json').write_text(json.dumps({'argv': argv, 'cwd': str(project), 'TMPDIR': os.environ.get('TMPDIR')}, indent=2) + '\n')
            env = dict(os.environ, JAVA_TOOL_OPTIONS='-XX:ActiveProcessorCount=2')
            with (work / 'gradle.log').open('w') as log:
                exit_code = run_invocation(argv, project, env, log, work)
            (work / 'exit.json').write_text(json.dumps({'exit_code': exit_code}) + '\n')
            xmls = sorted((project / 'app/build/test-results/testDebugUnitTest').glob('TEST-*.xml'))
            cases = []
            for xml in xmls:
                tree = ET.parse(xml).getroot()
                for case in tree.findall('testcase'):
                    failures = case.findall('failure') + case.findall('error')
                    cases.append({'name': case.attrib['name'], 'class': case.attrib['classname'],
                        'skipped': case.find('skipped') is not None,
                        'failures': [f.attrib.get('message', '') for f in failures]})
            result = {'exit_code': exit_code, 'xml': [str(p.relative_to(work)) for p in xmls], 'cases': cases, 'source_count': len(inputs)}
            receipt['variants'][variant] = result
            if len(cases) != len(variant_tests) or {c['name'] for c in cases} != variant_tests or any(c['skipped'] or c['class'] != TEST_CLASS for c in cases):
                raise AssertionError(variant + ': exact nonempty unskipped requested JUnit inventory required; setup/compiler failure is not RED')
            failed = {c['name']: c['failures'] for c in cases if c['failures']}
            if witness is None:
                if exit_code != 0 or failed:
                    raise AssertionError('Presentation GREEN failed: ' + repr(failed))
            else:
                name, message = witness
                # Independent regression must reject its own named invariant;
                # original normal allocation remains a compatibility control.
                if exit_code == 0 or name not in failed or not any(message in f for f in failed[name]):
                    raise AssertionError(variant + ': missing named native mutation witness: ' + repr(failed))
                allowed = {name}
                if variant in {'short-allocation', 'empty-outside-tools'}:
                    allowed.add('compactKeyboardConstrainedRecoveryFamily')
                additional = {
                    'short-allocation': 'correction content=1057 selected=true state=refusal: finite weighted lazy rows',
                    'empty-outside-tools': 'correction content=1057 selected=true state=refusal/query: ancestor admits complete native cell',
                    'ime-shell-allocation': 'correction content=1057 selected=true state=refusal/query: ancestor admits complete native cell',
                }
                if variant in additional and 'compactPostRefusalCorrectionAllocation' in failed:
                    if not all(additional[variant] in f for f in failed['compactPostRefusalCorrectionAllocation']):
                        raise AssertionError(variant + ': unexpected correction-family failure: ' + repr(failed))
                    allowed.add('compactPostRefusalCorrectionAllocation')
                if set(failed) - allowed:
                    raise AssertionError(variant + ': unrelated invariant failure: ' + repr(failed))
                if 'compactKeyboardConstrainedRecoveryFamily' in failed and variant != 'ime-shell-allocation':
                    prefix = 'keyboard content=1120 compact=true selected=true state=populated: finite row viewport' if variant == 'short-allocation' else 'keyboard content=311 compact=true selected=true state=empty/query: ancestor admits complete cell'
                    if not all(prefix in f for f in failed['compactKeyboardConstrainedRecoveryFamily']):
                        raise AssertionError(variant + ': unexpected keyboard-family failure: ' + repr(failed))
                result['expected_failure'] = {'test': name, 'message_prefix': message}
            result['accepted'] = True
        receipt['passed'] = True
    except BaseException as error:
        primary = error
        receipt['error'] = type(error).__name__ + ': ' + str(error)
        receipt['secondary_errors'] = getattr(error, '__notes__', [])
        if not isinstance(error, Exception):
            raise
    finally:
        try:
            (output / 'results.json').write_text(json.dumps(receipt, indent=2) + '\n')
        except BaseException as error:
            if primary is not None:
                primary.add_note('Results receipt failed: ' + repr(error))
                raise primary
            raise
    return receipt
