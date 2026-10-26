import AppKit
import AVFoundation
import Foundation
import Darwin

// Explicitly opt-in journey against cmd/native-fixture. Calls the actual native
// view actions and player. It does not stand in for independent human input QA.
extension App {
    func phasePlaybackStamp() -> PlaybackStamp {
        PlaybackStamp(player:player,item:player?.currentItem,account:accountScope,epoch:epoch,
            session:snapshot?.session ?? 0,occurrence:snapshot?.selected_occurrence,
            queue:snapshot?.queue.map(\.id) ?? [],rows:snapshot?.library.count ?? 0,
            settled:busy == 0 && snapshot?.authenticated == true && table.numberOfRows == 500,
            ready:player?.status == .readyToPlay && player?.currentItem?.status == .readyToPlay,
            failed:player?.error != nil || player?.currentItem?.status == .failed || snapshot?.transport == "failed",
            positionSeconds:player?.currentTime().seconds,rate:Double(player?.rate ?? 0),
            scrollY:Double(scroll.contentView.bounds.origin.y))
    }
    func finishPhaseMeasurement(passed:Bool,code:String? = nil) -> Bool {
        guard let recorder = phaseConfiguration?.recorder,!phaseFinalized else {return passed}
        phaseFinalized = true
        do {try recorder.finish(journeyPassed:passed,code:code);return recorder.status == "passed"}
        catch {return false}
    }
    func startFixtureJourney() {
        guard !journeyStarted else{return};journeyStarted = true
        fixtureJourneyTask = Task { @MainActor in
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
                if let recorder = self.phaseConfiguration?.recorder {
                    try recorder.begin(.populatedIdle,playback:self.phasePlaybackStamp())
                    try await Task.sleep(for:.milliseconds(3200))
                    try recorder.end(playback:self.phasePlaybackStamp())
                }
                self.command(["command":"clear_cache"])
                try await wait("owned cache clear settled") {self.busy == 0}
                self.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
                var begin = ProcessInfo.processInfo.systemUptime
                self.selectTrack()
                try await wait("cold platform decoder advances") {self.player?.rate ?? 0 > 0 && self.player?.currentTime().seconds ?? 0 > 0.2}
                if self.lastEffectCached {throw NSError(domain:"SoundQFixture",code:3,userInfo:[NSLocalizedDescriptionKey:"cold run unexpectedly cached"])}
                record("cold_selection_to_200ms_native_cursor",begin)
                if let recorder = self.phaseConfiguration?.recorder {
                    try await wait("phase audio boundary settled") {self.busy == 0}
                    try recorder.begin(.audioIdle,playback:self.phasePlaybackStamp())
                    try await Task.sleep(for:.milliseconds(3200))
                    try recorder.end(playback:self.phasePlaybackStamp())
                }
                // Scripted populated/audio-active list scrolling. Display/frame
                // instrumentation must be collected independently alongside it.
                begin = ProcessInfo.processInfo.systemUptime
                try self.phaseConfiguration?.recorder.begin(.audioScroll,playback:self.phasePlaybackStamp())
                for row in stride(from:0,to:500,by:7) {self.table.scrollRowToVisible(row);try await Task.sleep(for:.milliseconds(20))}
                try self.phaseConfiguration?.recorder.end(playback:self.phasePlaybackStamp())
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
                let original=self.snapshot!.selected_occurrence
                self.nextTrack()
                try await wait("native next selects different occurrence") {self.snapshot?.selected_occurrence != original && self.player?.rate ?? 0 > 0 && self.player?.currentTime().seconds ?? 0 > 0.2}
                self.previousTrack()
                try await wait("native previous selects original occurrence") {self.snapshot?.selected_occurrence == original && self.player?.rate ?? 0 > 0 && self.player?.currentTime().seconds ?? 0 > 0.2}
                let oldSession=self.snapshot!.session
                self.slider.doubleValue=29500;self.seek()
                try await wait("native EOF advances Rust queue exactly once") {self.snapshot?.session ?? 0 > oldSession && self.snapshot?.selected_occurrence != original && self.player?.rate ?? 0 > 0 && self.player?.currentTime().seconds ?? 0 > 0.2}
                let current=self.snapshot!.selected_occurrence
                let session=self.snapshot!.session
                self.queueCommand("queue_append",id:UInt64(self.snapshot!.library[0].id))
                try await wait("duplicate occurrence appended") {self.snapshot?.queue.count==501 && self.busy==0}
                let duplicate=self.snapshot!.queue.last!.id
                self.queueCommand("queue_move",id:duplicate,index:0)
                try await wait("move keeps current native decoder") {self.snapshot?.queue.first?.id==duplicate && self.snapshot?.session==session && self.snapshot?.selected_occurrence==current && self.busy==0}
                self.queueCommand("queue_remove",id:duplicate)
                try await wait("remove noncurrent keeps playback") {self.snapshot?.queue.count==500 && self.snapshot?.session==session && self.player?.rate ?? 0 > 0 && self.busy==0}
                self.command(["command":"pause"])
                try await wait("queue resting cursor settled") {self.busy==0 && self.player?.rate==0}
                self.slider.doubleValue=6000;self.seek()
                try await wait("resting cursor persisted") {self.busy==0 && abs((self.player?.currentTime().seconds ?? 0)-6)<0.1}
                self.command(["command":"queue_restore"])
                try await wait("restore queue is paused without decoder") {self.busy==0 && self.snapshot?.queue.count==500 && self.snapshot?.transport=="paused" && self.player==nil && self.snapshot?.position_ms==6000}
                self.command(["command":"resume"])
                try await wait("explicit resume uses restored native cursor") {self.player?.rate ?? 0 > 0 && self.player?.currentTime().seconds ?? 0 > 6.1}
                self.clearQueue()
                try await wait("clear queue retires decoder") {self.snapshot?.queue.isEmpty==true && self.player==nil && self.busy==0}
            } catch {
                outcome = "failed"
                failure = self.phaseConfiguration == nil ? String(describing:error) : "journey-failed"
            }
            self.player?.pause();self.observation = nil;self.player?.replaceCurrentItem(with:nil);self.player = nil
            if !self.finishPhaseMeasurement(passed:outcome == "passed",code:outcome == "passed" ? nil : "journey-failed") {outcome = "failed"}
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
