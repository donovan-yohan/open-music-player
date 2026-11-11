"""Generate the project-owned typed icon set. No Android build or source integration."""
from pathlib import Path
import json,re,hashlib,argparse,xml.etree.ElementTree as ET
from build_tokens import resolve, load_source, normalized
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'assets/icons/source.json'
def number(value):
    v=float(value)
    if not __import__('math').isfinite(v):raise ValueError('nonfinite geometry')
    return format(v,'.9g')
def paths(markup):
    root=ET.fromstring('<svg>'+markup+'</svg>');result=[]
    for node in root:
        tag=node.tag; a=node.attrib
        if set(a)-{'d','cx','cy','r','rx','ry','x','y','width','height','fill','stroke','stroke-width'}:raise ValueError('unsupported icon attribute')
        if tag=='path':d=a['d']
        elif tag in ('circle','ellipse'):
            x=float(a['cx']);y=float(a['cy']);rx=float(a.get('r',a.get('rx',0)));ry=float(a.get('r',a.get('ry',0)))
            if min(rx,ry)<=0:raise ValueError('invalid ellipse')
            d=f'M{number(x-rx)} {number(y)}a{number(rx)} {number(ry)} 0 1 0 {number(2*rx)} 0a{number(rx)} {number(ry)} 0 1 0 {number(-2*rx)} 0Z'
        elif tag=='rect':
            x,y,w,h=[float(a.get(k,0)) for k in ['x','y','width','height']];d=f'M{number(x)} {number(y)}h{number(w)}v{number(h)}h{number(-w)}Z'
        else:raise ValueError('unsupported icon geometry '+tag)
        if not re.fullmatch(r'[MmLlHhVvCcSsQqTtAaZz0-9eE+.,\s-]+',d):raise ValueError('invalid path')
        fill='SolidColor(Color.Black)' if a.get('fill')=='currentColor' else 'null'
        stroke='null' if a.get('stroke')=='none' else 'SolidColor(Color.Black)'
        width=number(a['stroke-width'])+'.toFloat()' if 'stroke-width' in a else 'SoundQComposeTokens.COMPONENT_ICON_STROKE_WIDTH'
        result.append((d,fill,stroke,width))
    return result

def render(source):
    if source.get('viewBox')!=[0,0,24,24]:raise ValueError('unexpected viewport')
    if source.get('strokeToken')!='component.icon.strokeWidth':raise ValueError('stroke authority mismatch')
    names=sorted(source['icons']);enum={n:n[0].upper()+n[1:] for n in names}
    if any(not re.fullmatch('[a-z][a-zA-Z0-9]*',n) for n in names):raise ValueError('invalid icon name')
    if len(set(enum.values()))!=len(names):raise ValueError('enum collision')
    lines=['// Generated from assets/icons/source.json. Do not edit.','// Pure visual assets; Compose compilation is engineering-owned.','package soundq.design.generated','','import androidx.compose.ui.graphics.Color','import androidx.compose.ui.graphics.SolidColor','import androidx.compose.ui.graphics.StrokeCap','import androidx.compose.ui.graphics.StrokeJoin','import androidx.compose.ui.graphics.vector.ImageVector','import androidx.compose.ui.graphics.vector.PathParser','import androidx.compose.ui.unit.dp','','enum class SoundQIcon { '+', '.join(enum.values())+' }','','val SoundQIcon.imageVector: ImageVector','    get() = when (this) {']
    lines += ['        SoundQIcon.'+enum[n]+' -> SoundQIconVectors.'+enum[n] for n in names]
    lines += ['    }','','private object SoundQIconVectors {']
    for n in names:
        lines += ['    val '+enum[n]+': ImageVector by lazy {','        ImageVector.Builder(name = "SoundQ'+enum[n]+'", defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 24f, viewportHeight = 24f).apply {']
        for d,fill,stroke,width in paths(source['icons'][n]):
            lines.append('            addPath(pathData = PathParser().parsePathString('+json.dumps(d)+').toNodes(), fill = '+fill+', stroke = '+stroke+', strokeLineWidth = '+width+', strokeLineCap = StrokeCap.Butt, strokeLineJoin = StrokeJoin.Miter)')
        lines += ['        }.build()','    }']
    lines += ['}']
    stroke_kind, stroke_value = resolve(load_source())[source['strokeToken']]
    stroke = normalized(stroke_kind, stroke_value)
    sprite=f'<svg xmlns="http://www.w3.org/2000/svg" fill="none" stroke="currentColor" stroke-width="{stroke}">'+''.join('<symbol id="'+n+'" viewBox="0 0 24 24">'+source['icons'][n]+'</symbol>' for n in names)+'</svg>\n'
    runtime='/* Generated from assets/icons/source.json; do not edit. */\nwindow.SoundQIcons = Object.freeze('+json.dumps(source['icons'],sort_keys=True,indent=2)+');\n'
    return {'SoundQIcons.kt':'\n'.join(lines)+'\n','icons.runtime.js':runtime,'soundq-icons.svg':sprite}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--check',action='store_true');args=p.parse_args();source=json.loads(SOURCE.read_text());outputs=render(source)
    assert outputs==render(json.loads(SOURCE.read_text()))
    for bad in ['<script>alert(1)</script>','<path d="not-a-path"/>','<image href="https://example.invalid"/>']:
        try:paths(bad)
        except (ValueError,KeyError):pass
        else:raise AssertionError('invalid geometry accepted')
    for name,text in outputs.items():
        path=ROOT/'generated'/name
        if args.check:assert path.read_text()==text,'generated icon drift: '+name
        else:path.write_text(text)
    count=len(source['icons']);assert outputs['SoundQIcons.kt'].count('ImageVector by lazy')==count
    ET.fromstring(outputs['soundq-icons.svg'])
    receipt={'status':'PASS','mode':'check' if args.check else 'build','iconCount':count,'sourceSha256':hashlib.sha256(SOURCE.read_bytes()).hexdigest(),'outputs':{name:hashlib.sha256(text.encode()).hexdigest() for name,text in outputs.items()},'checks':[str(count)+' typed enum variants and ImageVectors','repeat generation identical','invalid/non-path/external SVG refused','sprite XML parsed','default stroke uses canonical token'],'nativeCompiled':False}
    (ROOT/'evidence/icon-tests.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt,indent=2))
