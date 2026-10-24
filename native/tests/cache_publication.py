#!/usr/bin/env python3
"""Actual core/HTTP cache publication with unavailable hard links.
Loader interposition reproduces the target capability refusal, not Android SELinux.
The original device witness and fresh target runtime remain separate gates.
"""
import hashlib
import errno
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


def run_denied_link_child():
    out = Path(os.environ['SOUNDQ_REPAIR_EVIDENCE'])
    with tempfile.TemporaryDirectory(dir=out/'tmp') as tmp:
        root = Path(tmp)
        source = root/'deny-link.c'
        source.write_text(r'''
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
static int refused(const char *a,const char *b) {
    const char *path=getenv("SOUNDQ_LINK_WITNESS");
    int fd=path?open(path,O_WRONLY|O_CREAT|O_APPEND,0600):-1;
    if(fd>=0){write(fd,"link-denied\n",12);close(fd);}
    errno=EACCES;return -1;
}
static int refused_at(int a,const char*b,int c,const char*d,int flags){return refused(b,d);}
#ifdef __APPLE__
__attribute__((used)) static struct {const void *replacement;const void *original;}
interpose[] __attribute__((section("__DATA,__interpose")))={
    {(const void*)refused,(const void*)link},
    {(const void*)refused_at,(const void*)linkat}};
#else
int link(const char *a,const char *b){return refused(a,b);}
int linkat(int a,const char*b,int c,const char*d,int flags){return refused(b,d);}
#endif
''')
        library = root/('deny-link.dylib' if sys.platform == 'darwin' else 'deny-link.so')
        subprocess.run([os.environ.get('CC', 'cc'), '-shared', '-fPIC', str(source), '-o', str(library)], check=True)
        env = dict(os.environ)
        env['DYLD_INSERT_LIBRARIES' if sys.platform == 'darwin' else 'LD_PRELOAD'] = str(library)
        env['SOUNDQ_LINK_WITNESS'] = str(root/'link-witness')
        result = subprocess.run([sys.executable, str(Path(__file__).resolve()), '--child'], env=env,
                                capture_output=True, text=True, timeout=60)
        print(result.stdout+result.stderr)
        witness = root/'link-witness'
        print(json.dumps({'hardLinkCallsRefused': len(witness.read_text().splitlines()) if witness.exists() else 0,
                          'librarySha256': hashlib.sha256(Path(env['SOUNDQ_CORE_LIBRARY']).read_bytes()).hexdigest(),
                          'testSha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}))
        return result.returncode


if __name__ == '__main__' and '--child' not in sys.argv:
    raise SystemExit(run_denied_link_child())

sys.path.insert(0, os.environ['SOUNDQ_REPAIR_PROBES'])
import repair_support as p


class CachePublication(unittest.TestCase):
    def test_cold_warm_and_existing_collision_without_hard_link_capability(self):
        # Positive capability refusal prevents a protected interpreter stripping
        # preload settings from turning this regression into an ordinary pass.
        with tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as probe:
            source = Path(probe)/'probe'
            source.write_bytes(b'capability-witness')
            with self.assertRaises(OSError) as denied:
                os.link(source, Path(probe)/'linked')
            self.assertEqual(denied.exception.errno, errno.EACCES)
        with p.Server() as server, tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as tmp:
            h = p.new_core(server, tmp)
            try:
                self.assertTrue(p.restore(h)['ok'])
                self.assertTrue(p.library(h, 1)['ok'])
                cold = p.call(h, 1, 'select', track_id=1)
                self.assertTrue(cold['ok'], 'cold publication must not require hard-link permission: '+cold['code'])
                path = Path(cold['audio']['path'])
                self.assertEqual(path.read_bytes(), server.body)
                inode = path.stat().st_ino
                warm = p.call(h, 1, 'select', track_id=1)
                self.assertTrue(warm['audio']['cached'])
                self.assertEqual(server.downloads, 1)
                path.with_name('1.json').unlink()  # Exercise actual no-clobber EEXIST branch.
                peer = p.call(h, 1, 'select', track_id=1)
                self.assertTrue(peer['ok'], peer['code'])
                self.assertEqual(Path(peer['audio']['path']), path)
                self.assertEqual(path.stat().st_ino, inode)
                self.assertEqual(path.read_bytes(), server.body)
                path.write_bytes(b'X'*len(server.body))
                refused = p.call(h, 1, 'retry')
                self.assertEqual(refused['code'], 'cache_corrupt')
                self.assertNotIn('audio', refused)
                self.assertEqual(path.read_bytes(), b'X'*len(server.body))
                self.assertEqual(path.stat().st_ino, inode)
                self.assertEqual((server.downloads, server.descriptors), (3, 3))
                self.assertFalse(list(Path(tmp).rglob('*.partial')))
                self.assertFalse(list(Path(tmp).rglob('*.pending')))
            finally:
                p.C.sq_core_close(h)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]], verbosity=2)
