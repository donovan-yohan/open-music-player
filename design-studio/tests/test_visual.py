"""Tiny synthetic PNGs below are HARNESS TESTS, never native visual proof."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

spec=importlib.util.spec_from_file_location('studio',Path(__file__).parents[1]/'studio.py')
assert spec and spec.loader
s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)


def fixture_png(path, changed=False):
    def chunk(k,d): return struct.pack('>I',len(d))+k+d+struct.pack('>I',zlib.crc32(k+d)&0xffffffff)
    row=b'\x00'+bytes([255 if changed else 0,0,0,255])+bytes([30,40,50,255])
    path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',2,1,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(row))+chunk(b'IEND',b''))

class VisualTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='studio-harness-')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.captures=self.root/'captures';self.captures.mkdir()
        self.baselines=self.root/'baselines';self.baselines.mkdir()
        self.image=self.captures/'harness-only.png';fixture_png(self.image)
        self.env={'sdk':37,'fingerprint':'HARNESS ONLY','model':'synthetic','density':2,'fontScale':1,'locale':'en-US','renderer':'harness-only','widthDp':360}
        self.request=self.root/'request.json'
        s.save(self.request,{'schema':1,'sources':s.identities(),'environment':self.env,'cases':['harness-only']})
        self.receipt={'schema':1,'kind':'harness-only','sources':s.identities(),'environment':self.env,'cases':[{'id':'harness-only','file':self.image.name,'sha256':s.digest(self.image.read_bytes())}]}
        s.save(self.captures/'receipt.json',self.receipt)
    def baseline(self):
        (self.baselines/self.image.name).write_bytes(self.image.read_bytes())
        s.save(self.baselines/'harness-only.json',{'environment':self.env,'image_sha256':s.digest(self.image.read_bytes())})
    def test_pass_and_meaningful_pixel_diff(self):
        self.baseline()
        self.assertEqual('pass',s.verify(self.captures,self.request,self.baselines,True)['status'])
        fixture_png(self.image,True)
        self.receipt['cases'][0]['sha256']=s.digest(self.image.read_bytes());s.save(self.captures/'receipt.json',self.receipt)
        result=s.verify(self.captures,self.request,self.baselines,True)
        self.assertEqual('failed',result['status']);self.assertEqual(1,result['cases'][0]['changed_pixels']);self.assertEqual(255,result['cases'][0]['max_channel_delta'])
    def test_no_accept_on_verify(self):
        self.assertEqual('unaccepted',s.verify(self.captures,self.request,self.baselines,True)['cases'][0]['status'])
        self.assertEqual([],list(self.baselines.iterdir()))
    def test_wrong_hash_rejected(self):
        self.receipt['cases'][0]['sha256']='0'*64;s.save(self.captures/'receipt.json',self.receipt)
        with self.assertRaisesRegex(ValueError,'hash'):s.validate(self.captures,self.request,True)
    def test_changed_environment_rejected(self):
        self.receipt['environment']={**self.env,'sdk':99};s.save(self.captures/'receipt.json',self.receipt)
        with self.assertRaisesRegex(ValueError,'environment'):s.validate(self.captures,self.request,True)
    def test_changed_source_rejected(self):
        self.receipt['sources']={};s.save(self.captures/'receipt.json',self.receipt)
        with self.assertRaisesRegex(ValueError,'source'):s.validate(self.captures,self.request,True)
    def test_stale_request_rejected(self):
        req=s.load(self.request);req['sources']={};s.save(self.request,req)
        with self.assertRaisesRegex(ValueError,'stale'):s.validate(self.captures,self.request,True)
    def test_case_set_rejected(self):
        self.receipt['cases']=[];s.save(self.captures/'receipt.json',self.receipt)
        with self.assertRaisesRegex(ValueError,'cases'):s.validate(self.captures,self.request,True)
    def test_empty_image_rejected(self):
        self.image.write_bytes(b'')
        with self.assertRaisesRegex(ValueError,'PNG'):s.validate(self.captures,self.request,True)
    def test_harness_cannot_be_production(self):
        with self.assertRaisesRegex(ValueError,'native'):s.validate(self.captures,self.request)
    def test_native_build_provenance_requires_installed_hash(self):
        sources={'HARNESS':'0'*64}
        binding={'schema':1,'build_mode':'isolated-source-snapshot','sources':sources}
        proof={'producer':'design-studio/native_capture.py collect','apk_sha256':'a'*64,
               'installed_apk_sha256':'a'*64,'source_identity_sha256':s.digest(json.dumps(sources,sort_keys=True).encode()),
               'build_mode':'isolated-source-snapshot','embedded_binding':binding,
               'embedded_asset_sha256':s.digest(json.dumps(binding).encode('utf-8'))}
        # Complete valid proof gets past the embedded-binding prerequisite.
        s.validate_build(proof,sources)
        for installed in ('b'*64, None):
            with self.subTest(installed=installed):
                with self.assertRaisesRegex(ValueError,'native build provenance'):
                    s.validate_build({**proof,'installed_apk_sha256':installed},sources)
        s.validate_build(proof,sources)

    def test_legacy_proof_without_embedded_binding_remains_refused(self):
        sources={'HARNESS':'0'*64}
        with self.assertRaisesRegex(ValueError,'embedded build'):
            s.validate_build({},sources)
        proof={'producer':'design-studio/native_capture.py collect','apk_sha256':'a'*64,
               'installed_apk_sha256':'a'*64,'source_identity_sha256':s.digest(json.dumps(sources,sort_keys=True).encode())}
        with self.assertRaisesRegex(ValueError,'embedded build'):
            s.validate_build(proof,sources)
    def test_accept_exact_hash_and_agent_not_human(self):
        expected=s.digest(self.image.read_bytes())
        with self.assertRaisesRegex(ValueError,'hash'):
            s.accept(self.captures,self.request,self.baselines,'harness-only','0'*64,'Hotate','agent','Harness exercise',True)
        self.assertEqual([],list(self.baselines.iterdir()))
        s.accept(self.captures,self.request,self.baselines,'harness-only',expected,'Hotate','agent','Harness exercise',True)
        meta=s.load(self.baselines/'harness-only.json')
        self.assertEqual('agent',meta['reviewer_kind'])
        self.assertIn('not independent human approval',meta['approval_claim'])
        self.assertEqual('harness-only',meta['kind'])
    def test_accept_empty_rationale_rejected(self):
        with self.assertRaisesRegex(ValueError,'nonempty'):
            s.accept(self.captures,self.request,self.baselines,'harness-only',s.digest(self.image.read_bytes()),'Hotate','agent','  ',True)
    def test_report_cannot_write_baselines(self):
        result=s.verify(self.captures,self.request,self.baselines,True)
        with self.assertRaisesRegex(ValueError,'overlap'):
            s.report(self.baselines,result,self.captures,self.baselines)
        self.assertEqual([],list(self.baselines.iterdir()))
    def test_report_shows_real_current_baseline_and_diff(self):
        self.baseline()
        fixture_png(self.image,True)
        self.receipt['cases'][0]['sha256']=s.digest(self.image.read_bytes());s.save(self.captures/'receipt.json',self.receipt)
        result=s.verify(self.captures,self.request,self.baselines,True)
        out=self.root/'report'
        s.report(out,result,self.captures,self.baselines)
        self.assertTrue((out/'harness-only-baseline.png').exists())
        self.assertTrue((out/'harness-only-diff.png').exists())
        self.assertIn('HARNESS', (out/'index.html').read_text())
    def test_explicit_tolerance(self):
        other=self.root/'other.png';fixture_png(other,True)
        self.assertEqual('diff',s.compare(self.image,other)['status'])
        self.assertEqual('pass',s.compare(self.image,other,tolerance=255)['status'])

    def test_all_png_filters_decode_to_identical_pixels(self):
        # Two rows and two RGBA pixels exercise left, above and upper-left predictors.
        rows=[bytes([20,40,60,255,80,100,120,255]), bytes([30,50,70,255,90,110,130,255])]
        def chunk(kind,data):
            return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
        for kind in range(5):
            previous=bytes(8); raw=bytearray()
            for row in rows:
                raw.append(kind)
                for x,value in enumerate(row):
                    a=row[x-4] if x>=4 else 0; b=previous[x]; c=previous[x-4] if x>=4 else 0
                    p=a+b-c; distances=[abs(p-a),abs(p-b),abs(p-c)]
                    paeth=(a,b,c)[distances.index(min(distances))]
                    predictor=(0,a,b,(a+b)//2,paeth)[kind]
                    raw.append((value-predictor)&255)
                previous=row
            image=self.root/('HARNESS-filter-'+str(kind)+'.png')
            image.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',2,2,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b''))
            with self.subTest(filter=kind): self.assertEqual((2,2,b''.join(rows)),s.png(image))

if __name__=='__main__':unittest.main()
