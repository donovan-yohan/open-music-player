import AppKit
import AVFoundation
import Foundation
import Darwin

// Explicitly opt-in journey against cmd/native-fixture. Calls the actual native
// view actions and player. It does not stand in for independent human input QA.
extension App {
    func startFixtureJourney() {
        guard !journeyStarted else{return};journeyStarted = true
        Task { @MainActor in
            var samples = [[String:Any]]()
            var checks = [String]()
            let started = ProcessInfo.processInfo.systemUptime
            @MainActor func record(_ name:String,_ begin:Double) {
                samples.append(["name":name,"durationMs":(ProcessInfo.processInfo.systemUptime-begin)*1000,"nativePositionMs":(self.player?.currentTime().seconds ?? 0)*1000,"transport":self.snapshot?.transport ?? "none","cached":self.lastEffectCached])
            }
            @MainActor func wait(_ name:String,timeout:Double = 12,_ predicate: @MainActor ()->Bool) async throws {
                let until = ProcessInfo.processInfo.systemUptime+timeout
                while !predicate() {
                    if ProcessInfo.processInfo.systemUptime >= until {throw NSError(domain:"SoundQFixture",code:1,userInfo:[NSLocalizedDescriptionKey:name])}
                    try await Task.sleep(for:.milliseconds(40))
                }
                checks.append(name)
            }
            var outcome = "passed"
            var failure:String?
            do {
                try await wait("authenticated populated library") {self.snapshot?.library.count == 50 && self.busy == 0}
                for _ in 0..<9 {self.loadMore();try await wait("next page settled") {self.busy == 0}}
                try await wait("500 real Go library rows") {self.snapshot?.library.count == 500}
                self.command(["command":"clear_cache"])
                try await wait("owned cache clear settled") {self.busy == 0}
                self.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
                var begin = ProcessInfo.processInfo.systemUptime
                self.selectTrack()
                try await wait("cold platform decoder advances") {self.player?.rate ?? 0 > 0 && self.player?.currentTime().seconds ?? 0 > 0.2}
                if self.lastEffectCached {throw NSError(domain:"SoundQFixture",code:3,userInfo:[NSLocalizedDescriptionKey:"cold run unexpectedly cached"])}
                record("cold_selection_to_200ms_native_cursor",begin)
                // Scripted populated/audio-active list scrolling. Display/frame
                // instrumentation must be collected independently alongside it.
                begin = ProcessInfo.processInfo.systemUptime
                for row in stride(from:0,to:500,by:7) {self.table.scrollRowToVisible(row);try await Task.sleep(for:.milliseconds(20))}
                record("scripted_audio_active_scroll_500_rows",begin)
                self.command(["command":"pause"])
                try await wait("pause reaches platform decoder") {self.player?.rate == 0 && self.busy == 0}
                let paused = self.player!.currentTime().seconds
                try await Task.sleep(for:.milliseconds(250))
                if abs(self.player!.currentTime().seconds-paused)>0.05 {throw NSError(domain:"SoundQFixture",code:2,userInfo:[NSLocalizedDescriptionKey:"paused cursor advanced"])}
                checks.append("paused cursor stable")
                begin = ProcessInfo.processInfo.systemUptime
                self.slider.doubleValue = 6000;self.seek()
                try await wait("seek acknowledged by native cursor") {abs((self.player?.currentTime().seconds ?? 0)-6)<0.1}
                record("seek_to_native_cursor",begin)
                self.command(["command":"resume"])
                try await wait("resume advances actual cursor") {self.player?.currentTime().seconds ?? 0 > 6.2}
                self.command(["command":"pause"])
                try await wait("second pause settled") {self.busy == 0 && self.player?.rate == 0}
                self.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
                begin = ProcessInfo.processInfo.systemUptime;self.selectTrack()
                try await wait("warm cache platform decoder advances") {self.player?.rate ?? 0 > 0 && self.player?.currentTime().seconds ?? 0 > 0.2}
                if !self.lastEffectCached {throw NSError(domain:"SoundQFixture",code:4,userInfo:[NSLocalizedDescriptionKey:"warm run was not cached"])}
                record("warm_selection_to_200ms_native_cursor",begin)
                self.retry()
                try await wait("retry reloads and advances") {self.busy == 0 && self.player?.rate ?? 0 > 0 && self.player?.currentTime().seconds ?? 0 > 0.2}
                self.command(["command":"pause"])
                try await wait("final pause settled") {self.busy == 0 && self.player?.rate == 0}
            } catch {outcome = "failed";failure = String(describing:error)}
            self.player?.pause();self.observation = nil;self.player?.replaceCurrentItem(with:nil);self.player = nil
            var report:[String:Any] = ["status":outcome,"checks":checks,"samples":samples,"elapsedSeconds":ProcessInfo.processInfo.systemUptime-started,"pid":ProcessInfo.processInfo.processIdentifier,"sourceRef":ProcessInfo.processInfo.environment["OMP_SOURCE_REF"] ?? "unknown","limits":"Scripted production AppKit actions and actual AVPlayer cursor/rate. Not loopback capture, human audibility, display FPS, physical controls, underrun measurement or independent review."]
            if let failure {report["failure"] = failure}
            if let path = ProcessInfo.processInfo.environment["SOUNDQ_NATIVE_JOURNEY_REPORT"] {
                do {
                    let bytes = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
                    try bytes.write(to:URL(fileURLWithPath:path),options:.atomic)
                } catch {outcome = "failed"}
            }
            print("MACOS_NATIVE_JOURNEY_\(outcome.uppercased()) checks=\(checks.count)")
            // exit() does not dispatch AppKit's termination delegate. Retire the
            // decoder, timer and core explicitly before returning process status.
            self.timer?.invalidate();_ = self.bridge?.revoke();self.bridge = nil
            exit(outcome == "passed" ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }
}
