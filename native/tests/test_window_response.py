"""Window-free compilation/control tests, never live capture evidence."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


def lifecycle_controls(source):
    """Execute the real run tail with only public capture/target boundaries replaced."""
    text = source.read_text()
    helpers = text[text.index('struct Refusal:'):text.index('final class Observer:')]
    delegate = text[text.index('    func stream(_ stream: SCStream, didStopWithError'):
                    text.index('    func stream(_ stream: SCStream, didOutputSampleBuffer')]
    declarations = text[text.index('        var report:'):text.index('\n        do {\n', text.index('        var report:')) + 1]
    tail = text[text.index('            let capture=SCStream('):text.index('        print(report[')]
    return '''import Foundation
import CryptoKit
''' + helpers + '''
var scenario = ""
var starts = 0
var stops = 0
final class Timer {
    static var current: Timer?
    let action: (Timer) -> Void
    init(action: @escaping (Timer) -> Void) { self.action=action }
    static func scheduledTimer(withTimeInterval: Double, repeats: Bool, block: @escaping (Timer) -> Void) -> Timer {
        let timer=Timer(action:block);current=timer;return timer
    }
    func invalidate() { Timer.current=nil }
    func fire() { action(self) }
}
final class Target { var isTerminated = false }
final class Observer {
    let queue = DispatchQueue(label:"controls")
    var positive: UInt64? = 2
    var failure: String?
    var streamError = false
    var dwellTimer: DispatchWorkItem?
    var samples = [[String:Any]]()
    var geometry: [String:Any]? = [:]
    var input: (UInt64,UInt64)? = (1,1)
    var detected: UInt64? = 3
''' + delegate + '''}
final class SCStream {
    let probe: Observer
    init(filter: Int, configuration: Int, delegate: Observer) { probe=delegate }
    func addStreamOutput(_ observer: Observer, type: Kind, sampleHandlerQueue: DispatchQueue) throws {
        if scenario == "setup" { throw Refusal(code:"setup-refused") }
    }
    enum Kind { case screen }
    func suspendOperation() async {
        // Schedule only boundary results after this public operation suspends.
        // Production delegate, watchdog, aggregation and persistence stay exact.
        await withUnsafeContinuation { (_: UnsafeContinuation<Void,Never>) in
            Task { @MainActor in
                if scenario.hasSuffix("geometry") || scenario.hasSuffix("geometry-delegate") {
                    probe.queue.async { self.probe.failure="geometry-changed" }
                }
                if scenario.hasSuffix("delegate") {
                    probe.stream(self,didStopWithError:Refusal(code:"private-boundary-error"))
                }
                probe.queue.sync {}
                let snapshot=probe.queue.sync { ["failure":probe.failure ?? "none","streamError":String(probe.streamError),"starts":String(starts),"stops":String(stops),"operation":"pending"] }
                let root=URL(fileURLWithPath:CommandLine.arguments[1])
                try! JSONSerialization.data(withJSONObject:snapshot,options:.sortedKeys).write(to:root.appendingPathComponent(scenario+"-observer-before-watchdog.json"))
                try? await Task.sleep(nanoseconds:20_000_000)
                Timer.current!.fire()
            }
        }
    }
    func startCapture() async throws {
        starts += 1
        if scenario.hasPrefix("watchdog-start-") { await suspendOperation() }
        if scenario == "start" { throw Refusal(code:"start-refused") }
        if scenario == "delegate" || scenario == "delegate-primary" {
            if scenario == "delegate-primary" { probe.queue.sync { probe.failure="geometry-changed" } }
            probe.stream(self, didStopWithError:Refusal(code:"private-boundary-error"))
            probe.queue.sync {}
        }
        if scenario == "primary-stop" || scenario == "watchdog" { probe.queue.sync { probe.failure="geometry-changed" } }
        if scenario.hasPrefix("watchdog-stop-primary-") { probe.queue.sync { probe.failure="baseline-not-stable" } }
        if scenario == "cancel" || scenario == "cancel-stop" || scenario == "deadline" || scenario == "deadline-stop" {
            probe.positive=nil;probe.input=nil;probe.detected=nil
        }
        if scenario == "late-positive" { probe.positive=nil }
        if scenario == "cancel" || scenario == "cancel-stop" { withUnsafeCurrentTask { $0?.cancel() } }
    }
    func stopCapture() async throws {
        stops += 1
        if scenario.hasPrefix("watchdog-stop-") { await suspendOperation() }
        if scenario == "watchdog" { Timer.current!.fire() }
        if scenario == "late-positive" { probe.queue.sync { probe.positive=2 };return }
        if scenario != "normal" && scenario != "deadline" && scenario != "cancel" {
            throw NSError(domain:"private-boundary-error",code:1)
        }
    }
}
@main struct Controls {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let names=CommandLine.arguments.count > 2 ? [CommandLine.arguments[2]] : ["setup","start","delegate","delegate-primary","normal","stop","primary-stop","cancel","deadline","cancel-stop","deadline-stop","late-positive"]
        for name in names {
            scenario=name;starts=0;stops=0
            let url=root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
            let task=Task { @MainActor in await run(url:url) }
            let result=await task.value
            let data=try JSONSerialization.data(withJSONObject:result,options:.sortedKeys)
            print(String(data:data,encoding:.utf8)!)
        }
    }
    @MainActor static func run(url:URL) async -> [String:Any] {
        let filter=0,config=0
        let probe=Observer(),target=Target()
        let executable=url.appendingPathComponent("artifact")
        try! Data().write(to:executable)
        let hash=SHA256.hash(data:Data()).map{String(format:"%02x",$0)}.joined()
        let r=[0,0,1,1],p=[0.0,0.0],delta = -1,threshold=2.0,foreground=false,timeout=0.02
''' + declarations + '''        output=url;observer=probe
        func checkpoint() throws { try JSONSerialization.data(withJSONObject:report).write(to:url.appendingPathComponent("report.json")) }
        do {
''' + tail + '''        return ["scenario":scenario,"starts":starts,"stops":stops,"code":code,"report":report]
    }
}
'''


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

    def test_capture_lifecycle_preserves_primary_failure(self):
        source = Path(__file__).with_name('window_response.swift')
        fixture = self.root/'lifecycle.swift'; fixture.write_text(lifecycle_controls(source))
        binary = self.root/'lifecycle'
        result = subprocess.run(['swiftc', '-O', '-parse-as-library', '-swift-version', '5',
            '-num-threads', '2', str(fixture), '-o', str(binary)], capture_output=True, timeout=90)
        self.assertEqual(result.returncode, 0, 'CONTROL COMPILE FAILURE: ' + result.stderr.decode())
        out = self.root/'lifecycle-output'; out.mkdir()
        result = subprocess.run([str(binary), str(out)], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stderr, b'')
        watchdog = subprocess.run([str(binary), str(out), 'watchdog'], capture_output=True, timeout=10)
        with self.subTest(scenario='watchdog'):
            self.assertEqual(watchdog.returncode, 1)
            self.assertEqual(watchdog.stdout, b'')
            self.assertEqual(watchdog.stderr, b'capture-operation-timeout\n')
            timed = json.loads((out/'watchdog/report.json').read_bytes())
            self.assertEqual(timed['failure_codes'], ['geometry-changed', 'capture-operation-timeout'])
            self.assertEqual(timed['status'], 'failed')
            self.assertNotIn(str(self.root), json.dumps(timed))
        pending = {
            'watchdog-stop-normal': (1, 'none', False, ['capture-operation-timeout']),
            'watchdog-stop-delegate': (1, 'capture-stopped', True, ['capture-stopped', 'capture-operation-timeout']),
            'watchdog-stop-geometry': (1, 'geometry-changed', False, ['geometry-changed', 'capture-operation-timeout']),
            'watchdog-stop-geometry-delegate': (1, 'geometry-changed', True, ['geometry-changed', 'capture-stopped', 'capture-operation-timeout']),
            'watchdog-stop-primary-delegate': (1, 'baseline-not-stable', True, ['baseline-not-stable', 'capture-stopped', 'capture-operation-timeout']),
            'watchdog-stop-primary-geometry': (1, 'geometry-changed', False, ['baseline-not-stable', 'geometry-changed', 'capture-operation-timeout']),
            'watchdog-start-normal': (0, 'none', False, ['capture-operation-timeout']),
            'watchdog-start-delegate': (0, 'capture-stopped', True, ['capture-stopped', 'capture-operation-timeout']),
            'watchdog-start-geometry': (0, 'geometry-changed', False, ['geometry-changed', 'capture-operation-timeout']),
        }
        for name, (stops, failure, stream_error, codes) in pending.items():
            child = subprocess.run([str(binary), str(out), name], capture_output=True, timeout=10)
            with self.subTest(scenario=name):
                self.assertEqual(child.returncode, 1)
                self.assertEqual(child.stdout, b'')
                self.assertEqual(child.stderr, b'capture-operation-timeout\n')
                snapshot = json.loads((out/(name+'-observer-before-watchdog.json')).read_bytes())
                self.assertEqual(snapshot, {'failure': failure, 'streamError': str(stream_error).lower(),
                    'starts': '1', 'stops': str(stops), 'operation': 'pending'})
                timed = json.loads((out/name/'report.json').read_bytes())
                self.assertEqual(timed['failure_codes'], codes)
                self.assertEqual(timed['status'], 'failed')
                self.assertLessEqual(len(codes), 3)
                self.assertEqual(len(codes), len(set(codes)))
                self.assertNotIn(str(self.root), json.dumps(timed))
                self.assertNotIn('private-boundary-error', json.dumps(timed))
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        expected = {
            'setup': (0, 0, ['setup-refused']),
            'start': (1, 0, ['start-refused']),
            'delegate': (1, 0, ['capture-stopped']),
            'delegate-primary': (1, 0, ['geometry-changed', 'capture-stopped']),
            'normal': (1, 1, []),
            'stop': (1, 1, ['capture-cleanup-failed']),
            'primary-stop': (1, 1, ['geometry-changed', 'capture-cleanup-failed']),
            'cancel': (1, 1, ['collector-failed']),
            'deadline': (1, 1, ['baseline-or-input-timeout']),
            'cancel-stop': (1, 1, ['collector-failed', 'capture-cleanup-failed']),
            'deadline-stop': (1, 1, ['baseline-or-input-timeout', 'capture-cleanup-failed']),
            'late-positive': (1, 1, []),
        }
        self.assertEqual([row['scenario'] for row in rows], list(expected))
        for row in rows:
            name = row['scenario']; starts, stops, codes = expected[name]
            with self.subTest(scenario=name):
                self.assertEqual((row['starts'], row['stops']), (starts, stops))
                self.assertEqual(row['report']['failure_codes'], codes)
                self.assertEqual(row['code'], 0 if name in ('normal', 'late-positive') else 1)
                self.assertEqual(row['report']['status'], 'observed' if name in ('normal', 'late-positive') else 'failed')
                self.assertEqual(json.loads((out/name/'report.json').read_bytes()), row['report'])
                self.assertNotIn(str(self.root), json.dumps(row))
                self.assertNotIn('private-boundary-error', json.dumps(row))

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
