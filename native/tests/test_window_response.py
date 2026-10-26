"""Window-free compilation/control tests, never live capture evidence."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin', 'macOS public frameworks required')
class Collector(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR'))
        cls.root = Path(cls.tmp.name).resolve()
        cls.binary = cls.root/'window-response'
        source = Path(__file__).with_name('window_response.swift')
        result = subprocess.run(['swiftc','-O','-parse-as-library','-swift-version','5',
            '-num-threads','2',str(source),'-o',str(cls.binary)],capture_output=True,timeout=90)
        if result.returncode:
            raise AssertionError(result.stderr.decode())

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_math_and_pixel_controls(self):
        result=subprocess.run([str(self.binary),'--self-test'],capture_output=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr.decode())
        self.assertIn(b'clock-overflow',result.stdout)

    def args(self,out):
        return [str(self.binary),'--pid','2147483647','--window-id','1','--evidence',str(out),
            '--roi','0,0,20,20','--point','10,10','--scroll-pixels','-30',
            '--threshold','2','--timeout-seconds','1']

    def test_missing_target_is_safe_failure_not_capture(self):
        out=self.root/'missing'
        result=subprocess.run(self.args(out),capture_output=True,timeout=10)
        self.assertEqual(result.returncode,1)
        report=json.loads((out/'report.json').read_bytes())
        self.assertEqual(report['failure_codes'],['target-unavailable'])
        self.assertNotIn(str(self.root),json.dumps(report))

    def test_malformed_fields_not_silently_dropped(self):
        for index,(option,value) in enumerate([('--roi','0,junk,0,20,20'),('--point','10,junk,10'),('--timeout-seconds','nan'),('--scroll-pixels','0')]):
            out=self.root/f'bad-{index}';args=self.args(out);args[args.index(option)+1]=value
            result=subprocess.run(args,capture_output=True,timeout=10)
            self.assertEqual(result.returncode,1)
            report=json.loads((out/'report.json').read_bytes())
            self.assertIn(report['failure_codes'][0],['invalid-geometry','invalid-configuration'])

    def test_existing_output_never_overwritten(self):
        out=self.root/'existing';out.mkdir();marker=out/'marker';marker.write_text('keep')
        result=subprocess.run(self.args(out),capture_output=True,timeout=10)
        self.assertEqual(result.returncode,1)
        self.assertEqual(list(out.iterdir()),[marker])
        self.assertEqual(marker.read_text(),'keep')


if __name__ == '__main__':
    unittest.main()
