"""Strict named-case admission for the callback frontend's Android journey."""
import re


def passed(raw, exit_code, expected):
    if exit_code != 0 or not expected or len(set(expected)) != len(expected):
        return False
    try:
        text = raw.decode('utf-8', errors='strict')
    except UnicodeDecodeError:
        return False
    states = {case: 0 for case in expected}
    block = {}
    summary = False
    terminal = False
    for line in text.splitlines():
        if line.startswith('INSTRUMENTATION_STATUS: '):
            if summary or terminal:
                return False
            field = line.removeprefix('INSTRUMENTATION_STATUS: ')
            if '=' in field:
                key, value = field.split('=', 1)
                if key in block:
                    return False
                block[key] = value
        elif line.startswith('INSTRUMENTATION_STATUS_CODE: '):
            if summary or terminal:
                return False
            try:
                code = int(line.split(': ', 1)[1])
            except ValueError:
                return False
            identity = (block.get('class'), block.get('test'))
            if identity == (None, None) and code == 2:
                block = {}
                continue
            if identity not in states:
                return False
            if code == 1 and states[identity] == 0:
                states[identity] = 1
            elif code == 0 and states[identity] == 1:
                states[identity] = 2
            else:
                return False
            block = {}
        elif re.fullmatch(r'OK \(\d+ tests?\)', line.strip()):
            if summary or terminal or block or any(value != 2 for value in states.values()):
                return False
            count = re.search(r'\d+', line)
            if count is None or int(count[0]) != len(expected):
                return False
            summary = True
        elif line.startswith('INSTRUMENTATION_CODE: '):
            if not summary or terminal or line.strip() != 'INSTRUMENTATION_CODE: -1':
                return False
            terminal = True
        elif any(marker in line for marker in ('shortMsg=', 'INSTRUMENTATION_FAILED', 'FAILURES!!!')):
            return False
    return summary and terminal and not block and all(value == 2 for value in states.values())


if __name__ == '__main__':
    case = ('com.soundq.android.CallbackFrontendJourneyTest', 'journey')
    start = f'INSTRUMENTATION_STATUS: class={case[0]}\nINSTRUMENTATION_STATUS: test={case[1]}\nINSTRUMENTATION_STATUS_CODE: 1\n'
    success = start.replace('STATUS_CODE: 1', 'STATUS_CODE: 0')
    end = 'OK (1 test)\nINSTRUMENTATION_CODE: -1\n'
    good = (start + success + end).encode()
    assert passed(good, 0, [case])
    assert passed(b'INSTRUMENTATION_STATUS_CODE: 2\n' + good, 0, [case])
    for bad in [b'', end.encode(), good+b'INSTRUMENTATION_STATUS_CODE: 0\n',
                (success+start+end).encode(), (start+start+success+end).encode(),
                good.replace(b'STATUS_CODE: 0', b'STATUS_CODE: -2'),
                good.replace(b'OK (1 test)', b'OK (2 tests)'),
                b'INSTRUMENTATION_RESULT: shortMsg=Process crashed\n',
                good+b'\xff']:
        assert not passed(bad, 0, [case])
    assert not passed(good, 1, [case])
    print('PASS named instrumentation protocol controls')
