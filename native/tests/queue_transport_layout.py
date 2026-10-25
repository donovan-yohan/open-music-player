#!/usr/bin/env python3
"""Device-free regression for the production AppKit transport configuration.

The default probe compiles the exact buildWindow transport slice with recording
facades: it checks configuration, not native geometry. --appkit uses the same
slice and installed AppKit solver in an unattached view tree (no NSWindow,
application run loop, activation, input, bridge, fixture or audio). Both retain
full label bytes. Actual onscreen layout/readability and Full name remain
separate coordinator-owned runtime gates. Requires installed macOS swiftc.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = 'native/macos/Sources/main.swift'

FACADE = r'''
import Foundation
struct Priority: Equatable {let rawValue:Float;static let defaultLow=Self(rawValue:250)}
enum Orientation {case horizontal,vertical}
enum BreakMode {case byClipping,byTruncatingTail,byWordWrapping}
class Constraint {
 let lhs:Anchor;let rhs:Anchor;let constant:Double;var isActive=false
 init(_ lhs:Anchor,_ rhs:Anchor,_ constant:Double){self.lhs=lhs;self.rhs=rhs;self.constant=constant;Self.all.append(self)}
 static var all=[Constraint]()
}
class Anchor {
 func constraint(equalTo other:Anchor,constant:Double=0)->Constraint {Constraint(self,other,constant)}
}
class NSView:NSObject {let widthAnchor=Anchor();var horizontalCompression:Float=750
 func setContentCompressionResistancePriority(_ p:Priority,for axis:Orientation){if axis == .horizontal {horizontalCompression=p.rawValue}}
}
class NSCell {var truncatesLastVisibleLine=false}
class NSTextField:NSView {var stringValue:String;var lineBreakMode=BreakMode.byClipping
 var maximumNumberOfLines=0;var cell:NSCell?=NSCell()
 init(labelWithString value:String){stringValue=value}
 func setAccessibilityIdentifier(_ value:String){}
}
class NSButton:NSView {
 var title:String;var target:AnyObject?;var action:Selector?;var identifier=""
 init(title:String,target:AnyObject?,action:Selector?){self.title=title;self.target=target;self.action=action}
 func setAccessibilityIdentifier(_ value:String){identifier=value}
}
class NSStackView:NSView {
 var orientation=Orientation.vertical;var arrangedSubviews=[NSView]()
 override init(){super.init()}
 init(views:[NSView]){arrangedSubviews=views;super.init()}
 func addArrangedSubview(_ view:NSView){arrangedSubviews.append(view)}
}
'''

COMMON = r'''
final class Harness:NSObject {
 let content=NSStackView()
 let transportLabel=NSTextField(labelWithString:"No selection")
 let play=NSButton(title:"Play",target:nil,action:nil)
 @objc func selectTrack(){};@objc func toggle(){};@objc func retry(){}
 @objc func previousTrack(){};@objc func nextTrack(){};@objc func showQueue(){}
 func configure(){
__CONFIGURATION__
 }
}
func requireThat(_ condition:Bool,_ message:String){if !condition {print("FAIL \(message)");exit(1)}}
let h=Harness();h.configure()
let row=h.content.arrangedSubviews.last as! NSStackView
let buttons=row.arrangedSubviews.compactMap{$0 as? NSButton}
requireThat(buttons.map{$0.title} == ["Play selected","Previous","Play","Next","Retry","Queue"],"existing transport controls changed")
requireThat(row.arrangedSubviews.last === h.transportLabel,"title must remain mounted")
'''

CONFIG_CHECKS = r'''
requireThat(h.transportLabel.horizontalCompression < 500,"current-title horizontal compression must yield before native window current-width priority500")
requireThat(h.transportLabel.lineBreakMode == .byWordWrapping && h.transportLabel.maximumNumberOfLines == 1 && h.transportLabel.cell?.truncatesLastVisibleLine == true,"bounded title needs a single native line with last-line ellipsis")
let bound=Constraint.all.contains{$0.isActive && $0.lhs === row.widthAnchor && $0.rhs === h.content.widthAnchor && $0.constant == -48}
requireThat(bound,"transport width must follow content minus existing horizontal insets, not a fixed app width")
let title="SYNTHETIC QA — Long Night Transit / " + String(repeating:"Long recording disclosure segment / ",count:10) + "終点・終わり — Ω café e\u{301} 🚀"
h.transportLabel.stringValue=title
requireThat(Array(h.transportLabel.stringValue.utf8)==Array(title.utf8),"configuration must not shorten exact metadata")
print("PASS production-transport-configuration")
'''

APPKIT_CHECKS = r'''
h.content.orientation = .vertical
h.content.edgeInsets=NSEdgeInsets(top:20,left:24,bottom:20,right:24)
let host=NSView(frame:NSRect(x:0,y:0,width:900,height:700))
h.content.translatesAutoresizingMaskIntoConstraints=false
host.addSubview(h.content)
NSLayoutConstraint.activate([h.content.leadingAnchor.constraint(equalTo:host.leadingAnchor),h.content.trailingAnchor.constraint(equalTo:host.trailingAnchor),h.content.topAnchor.constraint(equalTo:host.topAnchor),h.content.bottomAnchor.constraint(equalTo:host.bottomAnchor)])
let title="SYNTHETIC QA — Long Night Transit / " + String(repeating:"Long recording disclosure segment / ",count:10) + "終点・終わり — Ω café e\u{301} 🚀"
let multiline="SYNTHETIC QA — Night Transit\n" + (1...12).map{"Movement \($0) / night passage\n"}.joined() + "終点・終わり — Ω café e\u{301} 🚀"
let short="Native Fixture500 · paused"
var failures=[String]()
func check(_ condition:Bool,_ message:String){if !condition {failures.append(message)}}
func observe(_ suite:String,_ stage:String,_ label:String,_ requested:CGFloat,_ buttonFont:CGFloat,_ labelFont:CGFloat)->[CGFloat] {
 h.transportLabel.font=NSFont.systemFont(ofSize:labelFont)
 for button in buttons {button.font=NSFont.systemFont(ofSize:buttonFont)}
 h.transportLabel.stringValue=label
 host.layoutSubtreeIfNeeded();host.layoutSubtreeIfNeeded()
 let intrinsic=h.transportLabel.intrinsicContentSize
 let heights=[h.transportLabel.frame.height,intrinsic.height,row.frame.height,row.fittingSize.height,h.content.fittingSize.height]
 let controls=buttons.map{b -> [String:Any] in
  let rect=b.convert(b.bounds,to:h.content)
  check(b.superview != nil && !b.isHidden,"control detached")
  check(rect.minX>=0 && rect.maxX<=requested+0.1 && rect.minY>=0 && rect.maxY<=700.1,"control outside content")
  check(b.frame.width+0.1>=b.intrinsicContentSize.width,"control compressed instead of metadata")
  check(b.font?.pointSize==buttonFont,"control font shrank")
  return ["title":b.title,"width":b.frame.width,"intrinsicWidth":b.intrinsicContentSize.width,"height":b.frame.height,"x":rect.minX,"y":rect.minY]
 }
 let result:[String:Any]=["suite":suite,"stage":stage,"requested":requested,"font":labelFont,"buttonFont":buttonFont,"titleBytes":label.utf8.count,"titleUTF8":Array(label.utf8),"contentWidth":h.content.frame.width,"contentHeight":h.content.frame.height,"contentFittingHeight":heights[4],"hostHeight":host.frame.height,"rowWidth":row.frame.width,"rowHeight":heights[2],"rowFittingHeight":heights[3],"labelWidth":h.transportLabel.frame.width,"labelHeight":heights[0],"intrinsicWidth":intrinsic.width,"intrinsicHeight":intrinsic.height,"maximumNumberOfLines":h.transportLabel.maximumNumberOfLines,"wraps":h.transportLabel.cell!.wraps,"singleLineCell":h.transportLabel.cell!.usesSingleLineMode,"truncatesLastVisibleLine":h.transportLabel.cell!.truncatesLastVisibleLine,"controls":controls]
 print(String(data:try! JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)
 check(abs(h.content.frame.width-requested)<0.1,"content escaped host width")
 check(abs(host.frame.height-700)<0.1 && abs(h.content.frame.height-700)<0.1,"parent escaped fixed host height")
 check(row.frame.width<=requested-48+0.1,"row escaped available width")
 check(h.transportLabel.frame.width>0 && !h.transportLabel.isHidden,"title disappeared")
 let rect=row.convert(row.bounds,to:h.content)
 check(rect.minY>=0 && rect.maxY<=700.1,"row outside fixed content height")
 check(h.transportLabel.font?.pointSize==labelFont,"metadata font shrank")
 check(Array(h.transportLabel.stringValue.utf8)==Array(label.utf8),"metadata bytes changed")
 return heights
}
// Preserve the original twelve normal/large horizontal observations unchanged.
for size:CGFloat in [13,20] {
 for requested:CGFloat in [900,1100] {
  host.setFrameSize(NSSize(width:requested,height:700))
  for (stage,label) in [("short",short),("long",title+" · paused"),("short-return",short)] {
   _=observe("horizontal-original",stage,label,requested,size,size)
  }
 }
}
// Height contribution is measured separately from a fixed parent's actual size:
// a roomy unattached host can absorb a tall row while fittingSize still grows.
for (buttonFont,labelFont): (CGFloat,CGFloat) in [(13,13),(20,20),(18,26)] {
 for requested:CGFloat in [900,1100] {
  host.setFrameSize(NSSize(width:requested,height:700))
  var baseline=[CGFloat]()
  for (stage,label) in [("short",short),("long",title+" · paused"),("multiline-lf",multiline+" · paused"),("multiline-crlf",multiline.replacingOccurrences(of:"\n",with:"\r\n")+" · paused"),("multiline-cr",multiline.replacingOccurrences(of:"\n",with:"\r")+" · paused"),("unicode-separators","Ω café e\u{301} 🚀\u{2028}終点\u{2029}終わり · paused"),("short-return",short)] {
   let heights=observe("bounded-height",stage,label,requested,buttonFont,labelFont)
   if baseline.isEmpty {baseline=heights}
   for (dimension,(actual,expected)) in zip(heights,baseline).enumerated() {
    check(abs(actual-expected)<0.1,"metadata expanded height contribution: \(stage) dimension\(dimension) \(actual) vs \(expected), fonts\(buttonFont)/\(labelFont), width\(requested)")
   }
  }
 }
}
for failure in failures {print("FAIL \(failure)")}
requireThat(failures.isEmpty,"transport geometry or exact-metadata regression")
print("PASS production-transport-appkit-view-solver")
'''


def configuration(source):
    # Stable, unique existing boundaries exclude window creation and presentation.
    start = '        let select = NSButton(title:"Play selected"'
    end = '        slider.target = self;slider.action = #selector(seek)'
    assert source.count(start) == source.count(end) == 1, 'ambiguous production transport extraction'
    return source[source.index(start):source.index(end)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--source-file', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--appkit', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    production = (args.source_file or args.source_root / SOURCE).read_bytes()
    extracted = configuration(production.decode())
    prelude = 'import AppKit\n' if args.appkit else FACADE
    probe = prelude + COMMON.replace('__CONFIGURATION__', extracted) + (APPKIT_CHECKS if args.appkit else CONFIG_CHECKS)
    (output / 'main.swift').write_text(probe)
    with tempfile.TemporaryDirectory(prefix='queue-layout-', dir=os.environ.get('TMPDIR')) as tmp:
        work = Path(tmp)
        argv = ['/usr/bin/swiftc', '-j', '2', '-num-threads', '2', '-module-cache-path', str(work / 'modules'), str(output / 'main.swift'), '-o', str(work / 'probe')]
        compiled = subprocess.run(argv, capture_output=True, timeout=120)
        ran = subprocess.run([str(work / 'probe')], capture_output=True, timeout=30) if compiled.returncode == 0 else None
        for name, result in [('compiler.log', compiled), ('runtime.log', ran)]:
            (output / name).write_bytes(result.stdout + result.stderr if result else b'NOT RUN\n')
    sha = lambda b: hashlib.sha256(b).hexdigest()
    receipt = {'scope': 'real AppKit unattached view solver' if args.appkit else 'recorded production configuration, not pixel geometry',
               'productionSha256': sha(production), 'testSha256': sha(Path(__file__).read_bytes()),
               'extractedSha256': sha(extracted.encode()), 'probeSha256': sha(probe.encode()),
               'compileArgv': argv, 'compileExit': compiled.returncode, 'runExit': ran.returncode if ran else None,
               'logs': {name: sha((output / name).read_bytes()) for name in ['compiler.log', 'runtime.log']}}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))
    print((output / 'compiler.log').read_text(), end='')
    print((output / 'runtime.log').read_text(), end='')
    raise SystemExit(compiled.returncode or (ran.returncode if ran else 1))


if __name__ == '__main__':
    main()
