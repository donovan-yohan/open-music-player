#!/usr/bin/env python3
"""Window-free actual AppKit auth controls and production shell geometry."""
import argparse,hashlib,json,os,subprocess,re
from pathlib import Path
from library_dock_presentation import production_probe,FILES
ROOT=Path(__file__).resolve().parents[2]
CASES=r'''
var passes=[String](),failures=[String]()
@MainActor func check(_ name:String,_ value:Bool) {if value {passes.append(name);print("PASS",name)} else {failures.append(name);print("FAIL",name)}}
let assets=try NativeAssets.load(root:URL(fileURLWithPath:CommandLine.arguments[1]))
for scale:CGFloat in [1,2] {for width:CGFloat in [760,960,1440] {for stage in ["empty","errors","pending"] {
 let a=App(),host=NSView(frame:NSRect(x:0,y:0,width:width,height:540));a.mountLibraryDock(in:host,assets:assets)
 let form=a.loginArea,shell=a.libraryDock!;shell.textScale=scale
 _ = a.authForm.changeMode(.register)
 if stage=="errors" {_ = a.authForm.begin(username:"",email:"",password:"",confirmation:"",epoch:1,account:1)}
 if stage=="pending" {_ = a.authForm.begin(username:"abc",email:"a@b.co",password:"secret-123",confirmation:"secret-123",epoch:1,account:1)}
 form.update(a.authForm);shell.updateAuthentication(false);shell.needsLayout=true;shell.layoutSubtreeIfNeeded();form.layoutSubtreeIfNeeded()
 let tag="\(Int(width))-\(Int(scale))-\(stage)"
 check("auth-native-secure-fields-"+tag,a.password is NSSecureTextField && form.confirmation is NSSecureTextField && !form.username.isHidden && !form.confirmation.isHidden)
 let controls:[NSControl]=[a.endpoint,form.username,a.email,a.password,form.confirmation,form.submit,form.modeButton]
 for (i,control) in controls.enumerated() {
  let rect=control.convert(control.bounds,to:shell.bodyDocument),natural=control.cell!.cellSize
  check("auth-complete-native-cell-\(i)-"+tag,control.frame.width>0 && control.frame.height>=natural.height && rect.minX>=0 && rect.maxX<=shell.bodyDocument.bounds.width && rect.minY>=0 && rect.maxY<=shell.bodyDocument.bounds.height)
  if i>0 {check("auth-pending-native-disabled-\(i)-"+tag,control.isEnabled == (stage != "pending"))}
 }
 check("auth-native-form-document-height-"+tag,form.frame.height==form.requiredHeight(width:form.bounds.width,scale:scale) && form.frame.maxY<=shell.bodyDocument.frame.height)
 check("auth-native-font-no-shrink-"+tag,a.password.font!.pointSize==14*scale && form.submit.font!.pointSize==14*scale)
 check("auth-native-feedback-"+tag,stage != "errors" || a.authForm.errors.count==4)
}}
}
print("AUTH_LAYOUT_SUMMARY passes=\(passes.count) failures=\(failures.count)");exit(failures.isEmpty ? 0:1)
'''
def main():
 p=argparse.ArgumentParser();p.add_argument('--source-root',type=Path,default=ROOT);p.add_argument('--output',type=Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
 probe,blocks=production_probe(a.source_root);header=probe[:probe.index('var failures=[String]')]
 source=a.output/'main.swift';source.write_text(header+'\n'+CASES)
 deps=[a.source_root/'native/macos/Sources'/name for name in FILES]+[a.source_root/'native/macos/Sources/LibraryMetadataDisclosure.swift']
 argv=['swiftc','-swift-version','6','-num-threads','2',str(source),*[str(d) for d in deps],'-o',str(a.output/'probe')]
 built=subprocess.run(argv,capture_output=True,timeout=120);(a.output/'compile.log').write_bytes(built.stdout+built.stderr)
 ran=subprocess.run([str(a.output/'probe'),str(a.source_root/'native/macos/Sources/Resources')],capture_output=True,timeout=30) if built.returncode==0 else None
 (a.output/'run.log').write_bytes(ran.stdout+ran.stderr if ran else b'NOT RUN')
 lines=ran.stdout.decode().splitlines() if ran else [];passes=[x[5:] for x in lines if x.startswith('PASS ')];failures=[x[5:] for x in lines if x.startswith('FAIL ')]
 expected=[]
 for scale in [1,2]:
  for width in [760,960,1440]:
   for stage in ['empty','errors','pending']:
    tag=f'{width}-{scale}-{stage}';expected+=['auth-native-secure-fields-'+tag]
    for i in range(7):
     expected+=['auth-complete-native-cell-'+str(i)+'-'+tag]
     if i>0:expected+=['auth-pending-native-disabled-'+str(i)+'-'+tag]
    expected += [prefix+tag for prefix in ['auth-native-form-document-height-','auth-native-font-no-shrink-','auth-native-feedback-']]
 from collections import Counter
 receipt=dict(passed=built.returncode==0 and ran is not None and ran.returncode==0 and Counter(passes)==Counter(expected),passes=passes,failures=failures,expected=expected,skips=0,compile_exit=built.returncode,run_exit=ran.returncode if ran else None,argv=argv,TMPDIR=os.environ.get('TMPDIR'),inputs={str(d.relative_to(a.source_root)):hashlib.sha256(d.read_bytes()).hexdigest() for d in deps},probe_sha256=hashlib.sha256(source.read_bytes()).hexdigest())
 (a.output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print((a.output/'compile.log').read_text());print((a.output/'run.log').read_text());return 0 if receipt['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
