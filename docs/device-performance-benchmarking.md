# Device performance benchmarking (Android)

`scripts/bench-android <label>` measures library-scroll smoothness on a
connected device. Run it with audio playing and the Library on screen —
playback is what drives the position-tick rebuilds, so a silent app
under-reports the cost being measured.

```bash
export ADB_SERVER_SOCKET=tcp:server-mac:5037   # if the device is on another host
export ANDROID_SERIAL=<serial>
scripts/bench-android my-change
```

## Why the usual tools do not work here

| Tool | Result on this app |
|---|---|
| `dumpsys gfxinfo <pkg>` | `Total frames rendered: 0`. Flutter draws into its own SurfaceView, so HWUI never sees the frames. |
| `dumpsys SurfaceFlinger --latency <layer>` | Returns only the refresh period on Android 14+; the per-frame buffer comes back empty. |
| `dumpsys SurfaceFlinger --timestats` | Works. Records present-to-present deltas per layer regardless of UI toolkit. This is the frame metric the script uses. |
| `top -H` | Never shows the Dart UI thread; it rarely enters the visible set. |

Flutter merges the Dart UI task runner onto the platform (main) thread on
Android, so there is no `1.ui` thread to find — UI work lives on `TID == PID`.
The script reads `utime + stime` for that thread straight from `/proc`.

That merge also matters for diagnosis: widget rebuilds and platform-channel
calls (for example `setVolume` on the audio voices) contend for the *same*
thread, so UI work can delay audio control calls.

## Baseline, Pixel 10 Pro, 120Hz, same library and same track playing

Fourteen fling pairs, `jankyFrames = 0` in all three — SurfaceFlinger's own
jank classifier never fired, so "late frames" below means a frame that took two
or more vsyncs to present, which is the stricter and more useful signal.

| Build | UI CPU per fling pair | Late frames |
|---|---|---|
| Debug | 386–422ms | 28–35% |
| Profile, before the notification-storm fix | 271ms | 14.5% |
| Profile, after the fix | 271ms | 10.5–15% |

Two things follow, and the first is much larger than the second:

1. **Build mode dominates.** A Flutter debug build runs Dart under the JIT with
   assertions on. It roughly doubles UI-thread cost and doubles the late-frame
   rate. Dogfooding a debug APK reports jank the shipped app does not have,
   which is why `scripts/dogfood-android` now defaults to `--profile`.
2. **The notification-storm fix is real but secondary on this device.** It
   removed genuine waste — 4 `PlaybackState` notifications per tick down to 1,
   and 1293 widgets rebuilt per notification down to 1, both gated by
   `client/test/perf/` — and it moves late frames down, but UI-thread CPU during
   a fling is dominated by list layout and paint, not by the rebuilds.

Measure before claiming a device-level win. The unit-level rebuild counts in
`client/test/perf/` are exact and cheap to run, but they are not a substitute
for this script.
