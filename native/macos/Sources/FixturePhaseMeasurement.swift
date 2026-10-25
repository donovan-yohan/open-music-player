import Foundation
import Darwin

// Diagnostic boundary counters only. No periodic collector or playback owner.
struct ProcessStamp {
    var monotonicNS: UInt64?
    var userUS: UInt64?
    var systemUS: UInt64?
    var rssBytes: UInt64?
    var errors: [String]

    static func live() -> ProcessStamp {
        var errors = [String]()
        var clock = timespec()
        let clockOK = clock_gettime(CLOCK_MONOTONIC_RAW, &clock) == 0
        let ns: UInt64? = clockOK && clock.tv_sec >= 0 && clock.tv_nsec >= 0 && clock.tv_nsec < 1_000_000_000 && UInt64(clock.tv_sec) <= (UInt64.max-UInt64(clock.tv_nsec))/1_000_000_000 ? UInt64(clock.tv_sec)*1_000_000_000+UInt64(clock.tv_nsec) : nil
        if ns == nil {errors.append("clock-read-failed")}
        var usage = rusage()
        let usageOK = getrusage(RUSAGE_SELF, &usage) == 0
        func micros(_ value: timeval) -> UInt64? {
            guard usageOK, value.tv_sec >= 0, value.tv_usec >= 0, value.tv_usec < 1_000_000,
                  UInt64(value.tv_sec) <= (UInt64.max-UInt64(value.tv_usec))/1_000_000 else {return nil}
            return UInt64(value.tv_sec)*1_000_000+UInt64(value.tv_usec)
        }
        let user = micros(usage.ru_utime), system = micros(usage.ru_stime)
        if user == nil || system == nil {errors.append("cpu-read-failed")}
        var info = mach_task_basic_info()
        let expected = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        var count = expected
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(expected)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let rss: UInt64? = result == KERN_SUCCESS && count == expected ? UInt64(info.resident_size) : nil
        if rss == nil {errors.append("rss-read-failed")}
        return ProcessStamp(monotonicNS:ns,userUS:user,systemUS:system,rssBytes:rss,errors:errors)
    }
    var object: [String:Any] {
        ["monotonic_ns":monotonicNS as Any? ?? NSNull(),"user_us":userUS as Any? ?? NSNull(),
         "system_us":systemUS as Any? ?? NSNull(),"rss_bytes":rssBytes as Any? ?? NSNull(),"failure_codes":errors]
    }
}

struct PlaybackStamp {
    // Strong witnesses survive replacement, so address reuse cannot pass identity.
    let player: AnyObject?
    let item: AnyObject?
    let account: UInt64
    let epoch: UInt64
    let session: UInt64
    let occurrence: UInt64?
    let queue: [UInt64]
    let rows: Int
    let settled: Bool
    let ready: Bool
    let failed: Bool
    let positionSeconds: Double?
    let rate: Double
    let scrollY: Double
}

enum FixturePhase: String, CaseIterable {
    case populatedIdle = "populated-idle"
    case audioIdle = "audio-active-idle"
    case audioScroll = "audio-active-scripted-row-jumps"
    var audio: Bool {self != .populatedIdle}
}
struct PhaseBoundary {
    let process: ProcessStamp
    let playback: PlaybackStamp
    let playerWitness: Int?
    let itemWitness: Int?
    var object: [String:Any] {
        ["process":process.object,"player_witness":playerWitness as Any? ?? NSNull(),
         "item_witness":itemWitness as Any? ?? NSNull(),"account_scope":playback.account,
         "epoch":playback.epoch,"session":playback.session,"occurrence":playback.occurrence as Any? ?? NSNull(),
         "rows":playback.rows,"settled":playback.settled,"ready":playback.ready,"failed":playback.failed,
         "position_seconds":playback.positionSeconds.flatMap {$0.isFinite ? $0 : nil} as Any? ?? NSNull(),
         "rate":playback.rate.isFinite ? playback.rate as Any : NSNull(),
         "scroll_y":playback.scrollY.isFinite ? playback.scrollY as Any : NSNull()]
    }
}
struct PhaseResult {
    let name: FixturePhase
    let start: PhaseBoundary
    let end: PhaseBoundary?
    let elapsedNS: UInt64?
    let cpuPercent: Double?
    let rssDeltaBytes: Int64?
    let cursorDeltaSeconds: Double?
    let displacement: Double?
    let errors: [String]
    var status: String {errors.isEmpty ? "passed" : "failed"}
    var object: [String:Any] {
        ["name":name.rawValue,"status":status,"start":start.object,"end":end?.object as Any? ?? NSNull(),
         "elapsed_ns":elapsedNS as Any? ?? NSNull(),"cpu_percent":cpuPercent as Any? ?? NSNull(),
         "rss_delta_bytes":rssDeltaBytes as Any? ?? NSNull(),"cursor_delta_seconds":cursorDeltaSeconds as Any? ?? NSNull(),
         "scroll_displacement":displacement as Any? ?? NSNull(),"failure_codes":errors]
    }
}
struct PhaseFailure: Error {let code: String}

final class FixturePhaseMeasurement {
    let runID: String
    let sourceCommit: String
    let sourceTree: String
    let manifestSHA256: String
    let read: () -> ProcessStamp
    let write: (Data) throws -> Void
    private(set) var phases = [PhaseResult]()
    private(set) var status = "running"
    private var errors = [String]()
    private var open: (FixturePhase,PhaseBoundary)?
    private var pending: FixturePhase?
    private var witnesses = [AnyObject]()
    private var journeyPassed: Bool?
    init(runID:String,sourceCommit:String,sourceTree:String,manifestSHA256:String,
         read:@escaping () -> ProcessStamp = ProcessStamp.live,write:@escaping (Data) throws -> Void) {
        self.runID = runID;self.sourceCommit = sourceCommit;self.sourceTree = sourceTree
        self.manifestSHA256 = manifestSHA256;self.read = read;self.write = write
    }
    private func witness(_ object: AnyObject?) -> Int? {
        guard let object else {return nil}
        if let index = witnesses.firstIndex(where: {$0 === object}) {return index+1}
        witnesses.append(object);return witnesses.count
    }
    private func boundary(_ playback: PlaybackStamp) -> PhaseBoundary {
        PhaseBoundary(process:read(),playback:playback,playerWitness:witness(playback.player),itemWitness:witness(playback.item))
    }
    func checkpoint() throws {
        let object: [String:Any] = ["schema":"soundq.macos.phase-diagnostic.v1","run_id":runID,
            "pid":ProcessInfo.processInfo.processIdentifier,"source_commit":sourceCommit,"source_tree":sourceTree,
            "manifest_sha256":manifestSHA256,"status":status,"journey_passed":journeyPassed as Any? ?? NSNull(),
            "failure_codes":errors,"pending_phase":pending?.rawValue as Any? ?? NSNull(),"phases":phases.map(\.object)]
        do {
            let bytes = try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
            guard bytes.count <= 65_536 else {throw PhaseFailure(code:"report-too-large")}
            try write(bytes)
        } catch {
            status = "failed";if !errors.contains("report-write-failed") {errors.append("report-write-failed")}
            throw PhaseFailure(code:"report-write-failed")
        }
    }
    func begin(_ phase: FixturePhase,playback:@autoclosure () -> PlaybackStamp) throws {
        guard status == "running", open == nil, phases.count < 3,
              !phases.contains(where:{$0.name == phase}) else {throw PhaseFailure(code:"phase-order-invalid")}
        pending = phase
        try checkpoint() // Before the start counter: disk I/O is outside the window.
        open = (phase,boundary(playback()))
    }
    func end(playback:PlaybackStamp,code:String? = nil) throws {
        guard let (name,start) = open else {throw PhaseFailure(code:"phase-not-open")}
        let end = boundary(playback)
        open = nil;pending = nil
        var codes = start.process.errors + end.process.errors
        if let code {codes.append(code)}
        let a = start.playback,b = end.playback
        for point in [a,b] {
            if point.rows != 500 || !point.settled {codes.append("unsettled-library")}
            if !point.scrollY.isFinite {codes.append("nonfinite-scroll")}
            if point.failed {codes.append("playback-failed")}
            if name.audio {
                if point.player == nil || point.item == nil || !point.ready || point.rate <= 0 || !point.rate.isFinite || point.occurrence == nil {codes.append("audio-not-ready")}
                if point.positionSeconds?.isFinite != true {codes.append("nonfinite-cursor")}
            } else if point.player != nil || point.item != nil {codes.append("idle-has-decoder")}
        }
        if a.account != b.account || a.epoch != b.epoch || a.session != b.session || a.occurrence != b.occurrence || a.player !== b.player || a.item !== b.item {codes.append("playback-identity-changed")}
        if a.queue != b.queue {codes.append("queue-changed")}
        var elapsed: UInt64?
        if let s = start.process.monotonicNS,let e = end.process.monotonicNS,e > s {elapsed = e-s}
        else {codes.append("invalid-clock-delta")}
        var cpu: Double?
        if let elapsed,let su = start.process.userUS,let eu = end.process.userUS,
           let ss = start.process.systemUS,let es = end.process.systemUS,eu >= su,es >= ss {
            let value = (Double(eu-su)+Double(es-ss))*100_000/Double(elapsed)
            if value.isFinite {cpu = value}
        }
        if cpu == nil {codes.append("invalid-cpu-delta")}
        var rss: Int64?
        if let s = start.process.rssBytes,let e = end.process.rssBytes,s <= Int64.max,e <= Int64.max {rss = Int64(e)-Int64(s)}
        if rss == nil {codes.append("invalid-rss-delta")}
        var cursor: Double?
        if name.audio,let s = a.positionSeconds,let e = b.positionSeconds,s.isFinite,e.isFinite {
            let delta = e-s
            if delta.isFinite {cursor = delta}
            // CMTime is read directly; 1 ms resolution, 100 ms endpoint allowance.
            // This rejects stalls/seeks; it is not proof of uninterrupted sound.
            if let elapsed {
                let expected = Double(elapsed)/1_000_000_000*a.rate
                if delta <= 0.001 || abs(delta-expected) > max(0.1,expected*0.1) || a.rate != b.rate {codes.append("cursor-progress-rejected")}
            }
        }
        let rawDisplacement = a.scrollY.isFinite && b.scrollY.isFinite ? b.scrollY-a.scrollY : nil
        let displacement = rawDisplacement.flatMap {$0.isFinite ? $0 : nil}
        if displacement == nil {codes.append("nonfinite-scroll")}
        if name == .audioScroll && (displacement == nil || displacement! <= 0) {codes.append("zero-scroll-displacement")}
        codes = Array(Set(codes)).sorted()
        phases.append(PhaseResult(name:name,start:start,end:end,elapsedNS:elapsed,cpuPercent:cpu,rssDeltaBytes:rss,cursorDeltaSeconds:cursor,displacement:displacement,errors:codes))
        try checkpoint() // End counter already read; never inside a measured window.
        if !codes.isEmpty {throw PhaseFailure(code:"phase-rejected")}
    }
    func finish(journeyPassed:Bool,code:String? = nil) throws {
        if let (name,start) = open {
            phases.append(PhaseResult(name:name,start:start,end:nil,elapsedNS:nil,cpuPercent:nil,rssDeltaBytes:nil,cursorDeltaSeconds:nil,displacement:nil,errors:["phase-interrupted"]))
            open = nil;pending = nil
        }
        self.journeyPassed = journeyPassed
        if let code {errors.append(code)}
        if phases.count != 3 {errors.append("missing-phases")}
        else if phases.map(\.name) != FixturePhase.allCases {errors.append("phase-order-invalid")}
        status = journeyPassed && errors.isEmpty && phases.allSatisfy({$0.status == "passed"}) ? "passed" : "failed"
        try checkpoint()
    }
}

// Validated before NSApplication/bridge/window/login. Opt-out returns nil without
// touching fixture files. No fallback to a personal Keychain or cache in this mode.
struct FixturePhaseConfiguration {
    let recorder: FixturePhaseMeasurement
    let email: String
    let password: String
    static func prepare(arguments:[String],environment:[String:String]) throws -> FixturePhaseConfiguration? {
        let requested = arguments.dropFirst().contains(where:{$0.hasPrefix("--measure-phases")}) || environment.keys.contains(where:{$0.hasPrefix("SOUNDQ_PHASE_")})
        guard requested else {return nil}
        guard arguments.dropFirst().sorted() == ["--fixture-journey","--measure-phases"] else {throw PhaseFailure(code:"invalid-flags")}
        func token(_ key:String,_ pattern:String) throws -> String {
            guard let value = environment[key],value.range(of:pattern,options:.regularExpression) != nil else {throw PhaseFailure(code:"invalid-identity")}
            return value
        }
        let run = try token("SOUNDQ_PHASE_RUN_ID","^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$")
        let commit = try token("SOUNDQ_PHASE_SOURCE_COMMIT","^[a-f0-9]{40}$")
        let tree = try token("SOUNDQ_PHASE_SOURCE_TREE","^[a-f0-9]{40}$")
        let manifest = try token("SOUNDQ_PHASE_MANIFEST_SHA256","^[a-f0-9]{64}$")
        guard environment["OMP_API_BASE_URL"] == "http://127.0.0.1:54761/api/v1" else {throw PhaseFailure(code:"invalid-endpoint")}
        func path(_ key:String) throws -> URL {
            guard let text = environment[key],text.hasPrefix("/"),text.count < 4096 else {throw PhaseFailure(code:"invalid-output")}
            let url = URL(fileURLWithPath:text)
            guard url.standardizedFileURL.path == text,url.resolvingSymlinksInPath().path == text else {throw PhaseFailure(code:"invalid-output")}
            return url
        }
        let home = try path("SOUNDQ_NATIVE_FIXTURE_HOME"),cache = try path("SOUNDQ_NATIVE_CACHE_ROOT"),report = try path("SOUNDQ_PHASE_REPORT")
        guard !FileManager.default.fileExists(atPath:report.path),
              cache.deletingLastPathComponent() == report.deletingLastPathComponent(),cache.lastPathComponent == "cache",
              home != report.deletingLastPathComponent(),
              FileManager.default.fileExists(atPath:report.deletingLastPathComponent().path) else {throw PhaseFailure(code:"invalid-output")}
        let credential = home.appendingPathComponent("credentials.json")
        guard credential.resolvingSymlinksInPath() == credential,
              let attributes = try? FileManager.default.attributesOfItem(atPath:credential.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,size.intValue <= 16_384,
              let bytes = try? Data(contentsOf:credential),
              let object = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              let email = object["email"] as? String,!email.isEmpty,email.utf8.count <= 320,
              let password = object["password"] as? String,!password.isEmpty,password.utf8.count <= 4096 else {throw PhaseFailure(code:"invalid-credentials")}
        let recorder = FixturePhaseMeasurement(runID:run,sourceCommit:commit,sourceTree:tree,manifestSHA256:manifest,write:{bytes in try bytes.write(to:report,options:.atomic)})
        try recorder.checkpoint()
        return FixturePhaseConfiguration(recorder:recorder,email:email,password:password)
    }
}
