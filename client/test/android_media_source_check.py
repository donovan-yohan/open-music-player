"""Source packaging + extracted audio_service mapping proof (no APK/device claim).
Run: python3 test/android_media_source_check.py
Uses resolved package_config; never mutates the dependency cache.
"""
import json
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlparse, unquote

client = Path(__file__).resolve().parents[1]
config = client / '.dart_tool/package_config.json'
package = next(p for p in json.loads(config.read_text())['packages']
               if p['name'] == 'audio_service')
uri = package['rootUri']
plugin = (Path(unquote(urlparse(uri).path)) if uri.startswith('file:')
          else config.parent / uri).resolve()
assert plugin == (client / 'third_party/audio_service').resolve(), plugin
res = client / 'android/app/src/main/res'
a = '{http://schemas.android.com/apk/res/android}'
tools = '{http://schemas.android.com/tools}'
vector = ET.parse(res / 'drawable/omp_notification.xml').getroot()
assert vector.tag == 'vector'
assert vector.attrib[a+'width'] == vector.attrib[a+'height'] == '24dp'
assert len(vector) == 1 and vector[0].tag == 'path'
assert vector[0].attrib[a+'fillColor'] == '#FFFFFFFF'
assert vector[0].attrib[a+'fillType'] == 'evenOdd'
# Geometry contract: inset bars and a Q with a transparent counter, no backdrop.
path = vector[0].attrib[a+'pathData']
assert path.startswith('M4,3H20V5H4Z M4,6H20V8H4Z M4,9H20V11H4Z')
assert 'M12,16' in path
assert ET.parse(res / 'raw/omp_notification_keep.xml').getroot().attrib[
    tools+'keep'] == '@drawable/omp_notification'
assert "androidNotificationIcon: 'drawable/omp_notification'" in (client/'lib/main.dart').read_text()
for name in ['skip_previous', 'play_arrow', 'pause', 'skip_next', 'stop']:
    assert list((plugin/'android/src/main/res').glob('drawable*/audio_service_'+name+'.png'))
print('PASS: native vector/config/keep and five standard action resources')

source = (plugin/'android/src/main/java/com/ryanheise/audioservice/AudioService.java').read_text()
match = re.search(r'public int getPlaybackState\(\) \{.*?\n    \}', source, re.S)
assert match is not None
method = match.group()
# Compile the exact resolved method, with Android constants stubbed only.
# This proves the mapping, NOT service lifecycle or MediaSession integration.
constants = {'NONE': 0, 'STOPPED': 1, 'PAUSED': 2, 'PLAYING': 3,
             'CONNECTING': 8, 'BUFFERING': 6, 'ERROR': 7}
fields = ''.join('static final int STATE_'+s+'='+str(i)+';' for s,i in constants.items())
for label, body, terminal in [('vendored', method, 'STOPPED')]:
    java = ('class MappingProof { static class PlaybackStateCompat {'+fields+'}'
      'enum State {idle, loading, buffering, ready, completed, error}'
      'State processingState; boolean playing;'+body+
      'void check(State s, boolean p, int expected) { processingState=s; playing=p;'
      'if(getPlaybackState()!=expected) throw new AssertionError(s+" "+p);}'
      'public static void main(String[] args) { MappingProof m=new MappingProof();')
    expected = {'idle':'NONE','loading':'CONNECTING','buffering':'BUFFERING',
                'ready':'PAUSED','completed':terminal,'error':'ERROR'}
    for state, value in expected.items():
        for playing in [False, True]:
            result = 'PLAYING' if playing and state in ['ready','completed'] else value
            java += f'm.check(State.{state}, {str(playing).lower()}, PlaybackStateCompat.STATE_{result});'
    java += 'System.out.println("PASS: '+label+' 12 mapping cases");}}'
    with tempfile.TemporaryDirectory() as tmp:
        f = Path(tmp)/'MappingProof.java'
        f.write_text(java)
        subprocess.run(['javac', str(f)], check=True)
        subprocess.run(['java', '-cp', tmp, 'MappingProof'], check=True)
