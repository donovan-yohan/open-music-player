#!/usr/bin/env python3
"""Verify sealed W10 subset through the immutable canonical exporter and aliases."""
import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--import-output',action='store_true')
a=p.parse_args()
B=ROOT/'design-input/spectral-w10'
provenance=json.loads((B/'provenance.json').read_text())
assert provenance['kind']=='consumed-subset-not-full-release'
for name,digest in provenance['files'].items():
    assert hashlib.sha256((B/name).read_bytes()).hexdigest()==digest,name
assert (B/'tools/build_tokens.py').read_bytes()==(ROOT/'design-input/scripts/build_tokens.py').read_bytes()
assert (B/'tokens/base.tokens.json').read_bytes()==(ROOT/'design-input/tokens/soundq.tokens.json').read_bytes()
spec=importlib.util.spec_from_file_location('spectral_canonical_exporter',B/'tools/build_tokens.py')
assert spec is not None and spec.loader is not None
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
document=json.loads((B/'tokens/base.tokens.json').read_text())
document.update(copy.deepcopy(json.loads((B/'tokens/spectral.roles.json').read_text())))
full=m.render(document)['SoundQComposeTokens.kt']
assert full==(B/'generated/SoundQComposeTokens.kt').read_text(),'released full output differs from canonical exporter'
lines=[line for line in full.splitlines() if line.strip().startswith('val W10_')]
assert len(lines)==23
output='// Generated canonical W10 subset: base + spectral.roles; select val W10_ only.\npackage soundq.design.generated\n\nimport androidx.compose.ui.graphics.Color\nimport androidx.compose.ui.unit.dp\n\nobject SoundQSpectralTokens {\n'+'\n'.join(lines)+'\n}\n'
target=ROOT/'designsystem/src/generated/kotlin/soundq/design/generated/SoundQSpectralTokens.kt'
if a.import_output:
    target.write_text(output)
assert target.read_text()==output,'native W10 output drift'
print(json.dumps({'spectral':'ok','roles':len(lines),'sealedMembers':len(provenance['files']),'archive':provenance['archiveSha256']}))
