#!/usr/bin/env python3
"""Bounded, dependency-free DTCG 2025.10 exporter (not a full spec validator).

Supports typed leaves/group type inheritance, whole-token curly aliases, sRGB
colors, px/rem dimensions, ms/s durations, cubicBezier, number, fontFamily and
fontWeight. Rejects unsupported constructs instead of silently approximating.
Android dimensions map CSS px to logical dp (font-size to sp), NOT device px;
rem resolves against the explicit 16px reference baseline. Durations are ms.
Exports include typed Compose Color/Dp/TextUnit/Easing and portable scalar adapters.
No platform runtime or shared client core is required or compiled by this script.
"""
import argparse
import copy
import json
import math
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'tokens/soundq.tokens.json'
OUTPUT = ROOT / 'generated'
TYPES = {'color', 'dimension', 'duration', 'cubicBezier', 'number', 'fontFamily', 'fontWeight'}
REF = re.compile(r'^\{([^{}]+)\}$')
NAME = re.compile(r'^[A-Za-z0-9_-]+$')


class TokenError(ValueError):
    pass


def numeric(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate(kind, value, path):
    def fail():
        raise TokenError(f'{path}: invalid {kind}: {value!r}')
    if kind in ('number', 'fontWeight'):
        if not numeric(value) or (kind == 'fontWeight' and not 1 <= value <= 1000):
            fail()
    elif kind == 'fontFamily':
        if not isinstance(value, str) or not value or any(c in value for c in '\n\r;{}<>"\\$'):
            fail()
    elif kind in ('dimension', 'duration'):
        units = ('px', 'rem') if kind == 'dimension' else ('ms', 's')
        if not isinstance(value, dict) or set(value) != {'value', 'unit'} or not numeric(value['value']) or value['unit'] not in units:
            fail()
        if kind == 'duration' and value['value'] < 0:
            fail()
    elif kind == 'cubicBezier':
        if not isinstance(value, list) or len(value) != 4 or not all(numeric(x) for x in value) or not (0 <= value[0] <= 1 and 0 <= value[2] <= 1):
            fail()
    elif kind == 'color':
        if not isinstance(value, dict) or not {'colorSpace', 'components'} <= set(value) or set(value) - {'colorSpace', 'components', 'alpha', 'hex'}:
            fail()
        components = value['components']
        if value['colorSpace'] != 'srgb' or not isinstance(components, list) or len(components) != 3 or not all(numeric(x) and 0 <= x <= 1 for x in components):
            fail()
        if not numeric(value.get('alpha', 1)) or not 0 <= value.get('alpha', 1) <= 1:
            fail()
        if 'hex' in value and not re.fullmatch(r'#[0-9a-fA-F]{6}', value['hex']):
            fail()
    else:
        fail()


def resolve(document):
    if not isinstance(document, dict):
        raise TokenError('root must be an object')
    tokens = {}
    def walk(group, prefix='', inherited=None):
        if not isinstance(group, dict):
            raise TokenError(f'{prefix}: expected object')
        if '$extends' in group or '$ref' in group:
            raise TokenError(f'{prefix}: unsupported reference construct')
        kind = group.get('$type', inherited)
        if '$value' in group:
            if not prefix or kind not in TYPES:
                raise TokenError(f'{prefix}: missing or unsupported type {kind!r}')
            if set(group) - {'$value', '$type', '$description', '$extensions', '$deprecated'}:
                raise TokenError(f'{prefix}: token cannot contain children or unsupported metadata')
            tokens[prefix] = (kind, group['$value'])
            return
        for name, child in group.items():
            if name.startswith('$'):
                if name not in {'$type', '$description', '$extensions', '$deprecated'}:
                    raise TokenError(f'{prefix}: unsupported metadata {name}')
                continue
            if not NAME.fullmatch(name):
                raise TokenError(f'invalid token name: {name}')
            walk(child, f'{prefix}.{name}' if prefix else name, kind)
    walk(document)
    if not tokens:
        raise TokenError('no tokens')
    result, visiting = {}, []
    def visit(path):
        if path in result:
            return result[path]
        if path in visiting:
            raise TokenError('alias cycle: ' + ' -> '.join(visiting + [path]))
        if path not in tokens:
            raise TokenError(f'unknown alias: {path}')
        visiting.append(path)
        kind, value = tokens[path]
        match = REF.fullmatch(value) if isinstance(value, str) else None
        if match:
            target_kind, value = visit(match[1])
            if kind != target_kind:
                raise TokenError(f'{path}: alias type mismatch ({kind} vs {target_kind})')
        validate(kind, value, path)
        visiting.pop()
        result[path] = (kind, copy.deepcopy(value))
        return result[path]
    for path in sorted(tokens):
        visit(path)
    # Every exporter identifier must stay unique, including camelCase -> kebab.
    for separator in ('-', '_'):
        names = [identifier(path, separator) for path in result]
        if len(set(names)) != len(names):
            raise TokenError('export identifier collision')
    return dict(sorted(result.items()))


def identifier(path, separator='-'):
    return re.sub(r'([a-z0-9])([A-Z])', r'\1-\2', path).replace('.', '-').replace('_', '-').lower().replace('-', separator)


def normalized(kind, value):
    if kind == 'color':
        rgb = ''.join(f'{int(x * 255 + 0.5):02X}' for x in value['components'])
        alpha = value.get('alpha', 1)
        return '#' + rgb + (f'{int(alpha * 255 + 0.5):02X}' if alpha != 1 else '')
    if kind == 'dimension':
        return value['value'] * (16 if value['unit'] == 'rem' else 1)
    if kind == 'duration':
        return value['value'] * (1000 if value['unit'] == 's' else 1)
    return value


def fmt(value):
    return format(value, '.12g')


def render(document):
    tokens = resolve(document)
    runtime = {path: normalized(kind, value) for path, (kind, value) in tokens.items()}
    compose = ['// Generated from tokens/soundq.tokens.json; do not edit.', '// Compose target; no production integration or native compilation implied.', 'package soundq.design.generated', '', 'import androidx.compose.animation.core.CubicBezierEasing', 'import androidx.compose.ui.graphics.Color', 'import androidx.compose.ui.text.font.FontWeight', 'import androidx.compose.ui.unit.dp', 'import androidx.compose.ui.unit.sp', '', 'object SoundQComposeTokens {']
    css = ['/* Generated from tokens/soundq.tokens.json; do not edit. */', ':root {']
    kt = ['// Generated; source: tokens/soundq.tokens.json. No production integration.', '// CSS px -> logical dp; font-size -> sp. Durations: ms. Velocity: CSS px/ms.', 'object SoundQDesignTokens {']
    xml = ['<?xml version="1.0" encoding="utf-8"?>', '<!-- Generated; CSS px -> dp, font-size -> sp; durations ms. -->', '<resources>']
    for path, (kind, source) in tokens.items():
        value = runtime[path]
        kebab, snake = identifier(path), 'soundq_' + identifier(path, '_')
        const = identifier(path, '_').upper()
        if kind == 'dimension':
            css_value = fmt(value) + 'px'
        elif kind == 'duration':
            css_value = fmt(value) + 'ms'
        elif kind == 'cubicBezier':
            css_value = 'cubic-bezier(' + ', '.join(map(fmt, value)) + ')'
        elif kind == 'fontFamily':
            css_value = json.dumps(value)
        else:
            css_value = value if isinstance(value, str) else fmt(value)
        if kind == 'color':
            argb_compose = '#FF' + value[1:] if len(value) == 7 else '#' + value[7:9] + value[1:7]
            compose.append(f'    val {const} = Color(0x{argb_compose[1:]}L)')
        elif kind == 'dimension':
            unit_compose = 'sp' if ('.fontSize.' in path or '.letterSpacing.' in path) else 'dp'
            compose.append(f'    val {const} = {fmt(value)}.{unit_compose}')
        elif kind == 'cubicBezier':
            floats = ', '.join(fmt(v) + ('.0f' if '.' not in fmt(v) else 'f') for v in value)
            compose.append(f'    val {const} = CubicBezierEasing({floats})')
        elif kind == 'fontWeight':
            compose.append(f'    val {const} = FontWeight({int(value)})')
        elif kind == 'fontFamily':
            compose.append(f'    const val {const}: String = {json.dumps(value)}')
        elif kind == 'duration':
            compose.append(f'    const val {const}: Int = {int(value)}')
        else:
            float_value = fmt(value) + ('.0f' if '.' not in fmt(value) else 'f')
            compose.append(f'    const val {const}: Float = {float_value}')
        css.append(f'  --{kebab}: {css_value};')
        if kind == 'color':
            argb = value if len(value) == 7 else '#' + value[7:9] + value[1:7]
            argb = '#FF' + argb[1:] if len(argb) == 7 else argb
            kt.append(f'    val {const}: Int = 0x{argb[1:]}.toInt()')
            xml.append(f'  <color name="{snake}">{argb}</color>')
        elif kind == 'cubicBezier':
            kt.append(f'    val {const}: FloatArray get() = floatArrayOf(' + ', '.join(fmt(x) + 'f' if '.' in fmt(x) else fmt(x) + '.0f' for x in value) + ')')
            xml.append(f'  <string name="{snake}" translatable="false">' + ','.join(map(fmt, value)) + '</string>')
        elif kind == 'fontFamily':
            kt.append(f'    const val {const}: String = {json.dumps(value)}')
            xml.append(f'  <string name="{snake}" translatable="false">{escape(value)}</string>')
        else:
            is_integer = kind in ('duration', 'fontWeight') and float(value).is_integer()
            literal = str(int(value)) if is_integer else fmt(value) + ('.0f' if '.' not in fmt(value) else 'f')
            kt.append(f'    const val {const}: {"Int" if is_integer else "Float"} = {literal}')
            if kind == 'dimension':
                unit = 'sp' if ('.fontSize.' in path or '.letterSpacing.' in path) else 'dp'
                xml.append(f'  <dimen name="{snake}">{fmt(value)}{unit}</dimen>')
            elif is_integer:
                xml.append(f'  <integer name="{snake}">{int(value)}</integer>')
            else:
                xml.append(f'  <item name="{snake}" type="dimen" format="float">{fmt(value)}</item>')
    css.append('}')
    kt.append('}')
    compose.append('}')
    xml.append('</resources>')
    js = '/* Generated; durations ms, dimensions CSS px, colors hex; do not edit. */\nwindow.SoundQTokens = Object.freeze(' + json.dumps(runtime, indent=2, ensure_ascii=False, allow_nan=False) + ');\n'
    return {'tokens.css': '\n'.join(css) + '\n', 'tokens.runtime.js': js,
            'SoundQDesignTokens.kt': '\n'.join(kt) + '\n', 'SoundQComposeTokens.kt': '\n'.join(compose) + '\n', 'soundq_design_tokens.xml': '\n'.join(xml) + '\n'}


def load_source(path=SOURCE):
    def pairs(items):
        obj = {}
        for key, value in items:
            if key in obj:
                raise TokenError(f'duplicate JSON key: {key}')
            obj[key] = value
        return obj
    return json.loads(path.read_text(), object_pairs_hook=pairs,
                      parse_constant=lambda value: (_ for _ in ()).throw(TokenError(f'nonfinite JSON: {value}')))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='read-only generation drift check')
    args = parser.parse_args(argv)
    try:
        outputs = render(load_source())
        if args.check:
            drift = [name for name, text in outputs.items() if not (OUTPUT / name).exists() or (OUTPUT / name).read_text() != text]
            if drift:
                raise TokenError('generated drift: ' + ', '.join(drift))
        else:
            OUTPUT.mkdir(parents=True, exist_ok=True)
            for name, text in outputs.items():
                (OUTPUT / name).write_text(text)
        print(json.dumps({'status': 'ok', 'mode': 'check' if args.check else 'build', 'tokens': len(resolve(load_source())), 'outputs': list(outputs)}))
        return 0
    except (TokenError, OSError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
