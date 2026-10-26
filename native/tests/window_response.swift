import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import ScreenCaptureKit

// Captured-window visual-change diagnostic, never physical presentation or FPS.
// Owns only its SCStream. The caller owns the target app and fixture lifetime.
struct Refusal: Error { let code: String }
func demand(_ ok: Bool, _ code: String) throws { if !ok { throw Refusal(code: code) } }
struct ROI {
    let x: Int, y: Int, width: Int, height: Int
    func valid(_ w: Int, _ h: Int) -> Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0 && width <= 512 && height <= 512 && x <= w-width && y <= h-height
    }
}
func distance(_ a: [UInt8], _ b: [UInt8]) -> Double? {
    guard !a.isEmpty, a.count == b.count else { return nil }
    var total = 0
    a.withUnsafeBufferPointer { left in
        b.withUnsafeBufferPointer { right in
            for index in 0..<left.count { total += abs(Int(left[index])-Int(right[index])) }
        }
    }
    return Double(total) / Double(a.count)
}
func upperNS(_ end: UInt64, _ start: UInt64, _ numer: UInt32, _ denom: UInt32) -> UInt64? {
    guard end >= start, numer > 0, denom > 0 else { return nil }
    let delta = end-start
    let (product, overflow) = delta.multipliedReportingOverflow(by:UInt64(numer))
    guard !overflow else { return nil }
    return product / UInt64(denom) + (product % UInt64(denom) == 0 ? 0 : 1)
}

final class Observer: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label:"soundq.window-response")
    let roi: ROI
    let threshold: Double
    let pid: pid_t
    let point: CGPoint
    let delta: Int32
    var foregroundRoute = false
    var samples = [[String:Any]]()
    var failure: String?
    var baseline: [UInt8]?
    var input: (UInt64,UInt64)?
    var positive: UInt64?
    var detected: UInt64?
    var geometry: [String:Any]?
    var geometryKey: String?
    var lastDisplay: UInt64?
    var streamError = false
    var armedAt: UInt64?
    var dwellTimer: DispatchWorkItem?
    var expectedScreen: CGRect?
    init(roi:ROI, threshold:Double, pid:pid_t, point:CGPoint, delta:Int32) {
        self.roi=roi; self.threshold=threshold; self.pid=pid; self.point=point; self.delta=delta
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.failure = "capture-stopped"; self.streamError = true }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let callback = mach_absolute_time()
        guard type == .screen, failure == nil, positive == nil else { return }
        guard samples.count < 2000 else { failure="sample-capacity-exceeded"; return }
        guard CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
              let info = attachments.first, let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue:rawStatus) else { failure="invalid-sample"; return }
        var record: [String:Any] = ["sequence":samples.count,"callback_ticks":String(callback),"status":rawStatus]
        defer { samples.append(record) }
        // Idle is not a new image observation. It may only anchor input after
        // a complete baseline and a quiet dwell; no fabricated negative image.
        if status == .idle {
            if input == nil, baseline != nil, let armedAt, callback > armedAt {
                var tb=mach_timebase_info_data_t(); mach_timebase_info(&tb)
                if let elapsed=upperNS(callback,armedAt,tb.numer,tb.denom),elapsed >= 200_000_000 { post() }
            }
            return
        }
        guard status == .complete else {
            if status == .blank || status == .suspended || status == .stopped { failure="capture-unavailable" }
            return
        }
        guard let display=(info[.displayTime] as? NSNumber)?.uint64Value,
              display > 0, display <= callback, lastDisplay == nil || display > lastDisplay!,
              let buffer=CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let content=info[.contentRect] as? [String:Any],
              let scale=info[.scaleFactor] as? NSNumber, let contentScale=info[.contentScale] as? NSNumber else { failure="sample-metadata-invalid"; return }
        lastDisplay=display
        let width=CVPixelBufferGetWidth(buffer),height=CVPixelBufferGetHeight(buffer)
        guard roi.valid(width,height), scale.doubleValue.isFinite, contentScale.doubleValue.isFinite else { failure="invalid-roi-or-scale"; return }
        let shape: [String:Any] = ["width_px":width,"height_px":height,"content_rect":content,"scale":scale,"content_scale":contentScale,"screen_rect":info[.screenRect] ?? NSNull()]
        guard let keyBytes=try? JSONSerialization.data(withJSONObject:shape,options:.sortedKeys),let key=String(data:keyBytes,encoding:.utf8) else { failure="invalid-geometry";return }
        if let geometryKey,geometryKey != key { failure="geometry-changed";return }
        geometryKey=key;geometry=shape
        guard CVPixelBufferLockBaseAddress(buffer,.readOnly) == kCVReturnSuccess else { failure="pixel-read-failed";return }
        defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        guard let address=CVPixelBufferGetBaseAddress(buffer) else { failure="pixel-read-failed";return }
        let stride=CVPixelBufferGetBytesPerRow(buffer)
        var bytes=[UInt8]();bytes.reserveCapacity(roi.width*roi.height*3)
        for y in roi.y..<(roi.y+roi.height) {
            let row=address.advanced(by:y*stride).assumingMemoryBound(to:UInt8.self)
            for x in roi.x..<(roi.x+roi.width) { bytes.append(row[x*4]);bytes.append(row[x*4+1]);bytes.append(row[x*4+2]) }
        }
        record["display_ticks"]=String(display)
        record["roi_sha256"]=SHA256.hash(data:Data(bytes)).map{String(format:"%02x",$0)}.joined()
        record["pixel_read_end_ticks"]=String(mach_absolute_time())
        if baseline == nil {
            baseline=bytes;armedAt=callback;record["predicate"]="baseline"
            let timer=DispatchWorkItem { [weak self] in
                guard let self,self.failure == nil,self.positive == nil else { return }
                self.post()
            }
            dwellTimer=timer;queue.asyncAfter(deadline:.now()+0.2,execute:timer)
            return
        }
        guard let change=distance(bytes,baseline!) else { failure="invalid-pixels";return }
        record["mean_absolute_rgb_change_0_255"]=change
        if input == nil {
            guard change <= 0.25 else { failure="baseline-not-stable";return }
            record["predicate"]="preinput-negative"
            var tb=mach_timebase_info_data_t();mach_timebase_info(&tb)
            if let armedAt,let dwell=upperNS(callback,armedAt,tb.numer,tb.denom),dwell>=200_000_000 { post() }
        } else if display >= input!.1 && change >= threshold {
            positive=display;detected=mach_absolute_time();record["predicate"]="first-qualified-change"
        } else { record["predicate"]="negative" }
    }
    func post() {
        guard input == nil else { return }
        guard let expectedScreen,
              let list=CGWindowListCopyWindowInfo(.optionIncludingWindow,CGWindowID(targetWindowID)) as? [[String:Any]],
              let entry=list.first,let owner=entry[kCGWindowOwnerPID as String] as? Int,owner==Int(pid),
              let bounds=entry[kCGWindowBounds as String] as? [String:Any],
              let current=CGRect(dictionaryRepresentation:bounds as CFDictionary),current==expectedScreen,
              current.contains(point) else { failure="window-moved-or-input-outside-target";return }
        guard let event=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:delta,wheel2:0,wheel3:0) else { failure="event-create-failed";return }
        event.location=point
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer,value:Int64(targetWindowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value:Int64(targetWindowID))
        if foregroundRoute && NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            failure="foreground-target-not-active";return
        }
        let before=mach_absolute_time()
        if foregroundRoute { event.post(tap:.cghidEventTap) } else { event.postToPid(pid) }
        let after=mach_absolute_time()
        input=(before,after)
    }
    var targetWindowID: UInt32 = 0
}

@main struct Main {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in await run() }
        app.run()
    }
    @MainActor
    static func run() async {
        var report: [String:Any] = ["schema":"soundq.window-response.v1","status":"failed","failure_codes":[String](),"physical_presentation_available":false,"fps":NSNull(),"response_lower_ns":0,
            "limits":["captured-window-change-not-physical-presentation","any-roi-change-not-semantic-causality","synthetic-os-event-submission-not-delivery","caller-must-exclude-progress-caret-and-unrelated-animation","no-audio-qualification"]]
        var output: URL?
        var stream: SCStream?
        var observer: Observer?
        var code=1
        var watchdog: Timer?
        defer { watchdog?.invalidate() }
        do {
            if CommandLine.arguments == [CommandLine.arguments[0],"--self-test"] {
                try demand(distance([0,255],[255,0]) == 255,"pixel-distance")
                try demand(distance([],[]) == nil,"empty-pixels")
                try demand(ROI(x:0,y:0,width:4,height:4).valid(4,4),"roi-positive")
                try demand(!ROI(x:Int.max,y:0,width:4,height:4).valid(4,4),"roi-overflow")
                try demand(upperNS(11,10,125,3) == 42,"outward-rounding")
                try demand(upperNS(1,2,1,1) == nil,"clock-reversal")
                try demand(upperNS(UInt64.max,0,2,1) == nil,"clock-overflow")
                print("PASS pixel-distance empty-pixels roi-positive roi-overflow outward-rounding clock-reversal clock-overflow")
                exit(0)
            }
            let foreground=CommandLine.arguments.contains("--foreground-route")
            let args=Array(CommandLine.arguments.dropFirst()).filter{$0 != "--foreground-route"}
            try demand(args.count==16,"invalid-arguments")
            var options=[String:String]()
            for i in stride(from:0,to:args.count,by:2) {
                try demand(options[args[i]] == nil,"duplicate-option");options[args[i]]=args[i+1]
            }
            try demand(Set(options.keys)==Set(["--pid","--window-id","--evidence","--roi","--point","--scroll-pixels","--threshold","--timeout-seconds"]),"invalid-arguments")
            guard let text=options["--evidence"],text.hasPrefix("/"), !text.split(separator:"/").contains("..") else { throw Refusal(code:"invalid-output") }
            let url=URL(fileURLWithPath:text)
            try demand(url.resolvingSymlinksInPath().path==url.path && !FileManager.default.fileExists(atPath:url.path),"output-must-be-new")
            try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);output=url
            func checkpoint() throws { try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]).write(to:url.appendingPathComponent("report.json"),options:.atomic) }
            try checkpoint()
            guard let pid=Int32(options["--pid"]!),pid>0,let windowID=UInt32(options["--window-id"]!),windowID>0,
                  let threshold=Double(options["--threshold"]!),threshold.isFinite,threshold>=1,threshold<=255,
                  let timeout=Double(options["--timeout-seconds"]!),timeout.isFinite,timeout>=0.5,timeout<=30,
                  let delta=Int32(options["--scroll-pixels"]!),delta != 0,delta>=(-2000),delta<=2000 else { throw Refusal(code:"invalid-configuration") }
            let rawR=options["--roi"]!.split(separator:",",omittingEmptySubsequences:false)
            let rawP=options["--point"]!.split(separator:",",omittingEmptySubsequences:false)
            let r=rawR.compactMap{Int($0)},p=rawP.compactMap{Double($0)}
            try demand(rawR.count==4 && rawP.count==2 && r.count==4 && p.count==2 && p.allSatisfy{$0.isFinite && abs($0)<100000},"invalid-geometry")
            let roi=ROI(x:r[0],y:r[1],width:r[2],height:r[3]);try demand(roi.valid(32768,32768),"invalid-roi")
            _ = NSApplication.shared // Initialize the supported WindowServer connection.
            guard let target=NSRunningApplication(processIdentifier:pid),!target.isTerminated,
                  let executable=target.executableURL, let bundle=target.bundleIdentifier else { throw Refusal(code:"target-unavailable") }
            let hash=SHA256.hash(data:try Data(contentsOf:executable)).map{String(format:"%02x",$0)}.joined()
            report["pid"]=pid;report["window_id"]=windowID;report["application_id"]=bundle;report["executable_sha256"]=hash
            try demand(CGPreflightScreenCaptureAccess(),"screen-capture-permission-unavailable")
            try demand(CGPreflightPostEventAccess(),"event-post-permission-unavailable")
            let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
            guard let window=content.windows.first(where:{$0.windowID==windowID && $0.owningApplication?.processID==pid && $0.owningApplication?.bundleIdentifier==bundle}) else { throw Refusal(code:"window-owner-mismatch") }
            let filter=SCContentFilter(desktopIndependentWindow:window)
            let config=SCStreamConfiguration()
            config.width=Int(filter.contentRect.width*Double(filter.pointPixelScale));config.height=Int(filter.contentRect.height*Double(filter.pointPixelScale))
            try demand(config.width>0 && config.width<=16384 && config.height>0 && config.height<=16384 && roi.valid(config.width,config.height),"invalid-capture-size")
            config.pixelFormat=kCVPixelFormatType_32BGRA;config.colorSpaceName=CGColorSpace.sRGB
            config.minimumFrameInterval=CMTime(value:1,timescale:60);config.queueDepth=3
            config.showsCursor=false;config.capturesAudio=false;config.ignoreShadowsSingleWindow=true
            config.scalesToFit=false
            if #available(macOS 15.0,*) { config.captureMicrophone=false;config.captureDynamicRange = .SDR }
            let probe=Observer(roi:roi,threshold:threshold,pid:pid,point:CGPoint(x:p[0],y:p[1]),delta:delta);observer=probe
            probe.foregroundRoute=foreground
            probe.expectedScreen=window.frame;probe.targetWindowID=windowID
            try demand(window.frame.contains(probe.point),"input-outside-target")
            let capture=SCStream(filter:filter,configuration:config,delegate:probe);stream=capture
            try capture.addStreamOutput(probe,type:.screen,sampleHandlerQueue:probe.queue)
            var tb=mach_timebase_info_data_t();try demand(mach_timebase_info(&tb)==KERN_SUCCESS,"timebase-unavailable")
            report["clock"]=["domain":"mach-absolute-time","unit":"tick","numer":tb.numer,"denom":tb.denom]
            report["roi_px"]=r;report["input_point_screen_points"]=p;report["scroll_pixels"]=delta;report["threshold"]=threshold
            report["input_route"]=foreground ? "cg-hid-foreground" : "cg-post-to-pid"
            report["capture_requested_interval"]=["value":1,"timescale":60];report["status"]="running";try checkpoint()
            // Public capture startup/teardown may never return when the OS
            // refuses a session. Preserve failure and let process exit release
            // capture ownership; never leave an unbounded helper behind.
            watchdog=Timer.scheduledTimer(withTimeInterval:timeout+5,repeats:false) { _ in
                let failure:[String:Any] = ["schema":"soundq.window-response.v1","status":"failed","failure_codes":["capture-operation-timeout"],"physical_presentation_available":false,"fps":NSNull()]
                if let bytes=try? JSONSerialization.data(withJSONObject:failure,options:.sortedKeys) {
                    try? bytes.write(to:url.appendingPathComponent("report.json"),options:.atomic)
                }
                fputs("capture-operation-timeout\n",stderr);exit(1)
            }
            try await capture.startCapture()
            let deadline=ProcessInfo.processInfo.systemUptime+timeout
            while ProcessInfo.processInfo.systemUptime<deadline {
                if probe.queue.sync(execute:{probe.positive != nil || probe.failure != nil}) { break }
                if target.isTerminated { probe.queue.sync{probe.failure="target-exited"};break }
                try await Task.sleep(nanoseconds:10_000_000)
            }
            probe.queue.sync { probe.dwellTimer?.cancel() }
            try await capture.stopCapture();stream=nil
            try demand(!target.isTerminated,"target-exited")
            let finalHash=SHA256.hash(data:try Data(contentsOf:executable)).map{String(format:"%02x",$0)}.joined()
            try demand(finalHash==hash,"target-artifact-changed")
            try probe.queue.sync {
                report["samples"]=probe.samples;report["geometry"]=probe.geometry ?? [:]
                if let input=probe.input { report["input_ticks"]=[String(input.0),String(input.1)] }
                if let failure=probe.failure { throw Refusal(code:failure) }
                guard let positive=probe.positive,let input=probe.input,let detected=probe.detected,
                      let upper=upperNS(positive,input.0,tb.numer,tb.denom),let detection=upperNS(detected,input.0,tb.numer,tb.denom) else { throw Refusal(code:probe.input == nil ? "baseline-or-input-timeout":"no-qualified-captured-change") }
                report["response_upper_ns"]=upper;report["detected_by_upper_ns"]=detection;report["status"]="observed";code=0
            }
        } catch let failure as Refusal { report["status"]="failed";report["failure_codes"]=[failure.code] }
        catch { report["status"]="failed";report["failure_codes"]=["collector-failed"] }
        observer?.queue.sync { observer?.dwellTimer?.cancel() }
        if let stream { do { try await stream.stopCapture() } catch { report["status"]="failed";report["failure_codes"]=["capture-cleanup-failed"];code=1 } }
        if let observer { observer.queue.sync { report["samples"]=observer.samples } }
        if let output { do { try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]).write(to:output.appendingPathComponent("report.json"),options:.atomic) } catch { report["status"]="failed";fputs("report-persistence-failed\n",stderr);code=1 } }
        print(report["status"] as? String ?? "failed");exit(Int32(code))
    }
}
