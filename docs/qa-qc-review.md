# Joseon QA, performance, and security review

Reviewed from source on 2026-10-15, against `main` at `134d3e6`. Product code was not changed. This is a read of the macOS app (Swift + Metal). JoseonPC was not re-audited; the parity notes at the end use only what this repository already says about it, plus the public repo landing page.

This environment is Linux and has no Swift toolchain, so `swift test` and `swift build` were not run. No CPU, GPU, or battery numbers below were measured for this review. Sizes are arithmetic from constants in the source. Timing budgets are the assertions already written in the tests, not results from this pass.

## How the app is put together

`Package.swift` (Swift tools 6.0, language mode Swift 5, macOS 14.4+) builds five modules and no external packages:

| Module | Role |
|---|---|
| `JoseonCore` | Contracts, ring buffer, spectrum / loudness / stereo, `AnalysisEngine` |
| `JoseonCapture` | Core Audio process tap, measurement input, Qobuz now-playing via Accessibility |
| `JoseonHeadphones` | AutoEQ curves compiled into Swift source, SPL, measurement math |
| `JoseonRender` | Metal panels. Input is `AnalysisFrame` only |
| `JoseonApp` | Windows, menu bar, settings, updater |

Data flow, from the comment at the top of `Sources/JoseonCore/Contracts.swift`: the tap writes a `StereoRingBuffer`, the analysis queue reads it, panels pull `AnalysisFrame` from a display link. That split is real in the code, not only in the comment.

The audio path is the strongest part of the project. The defects that matter are a display-link frame cap that is computed and then ignored, a permission banner that ignores a distinction the tap already makes, and a security story in `SECURITY.md` and `docs/details.html` that is stricter than `Updater.swift` and silent about Accessibility.

## 1. Quality

### Architecture and maintainability

The layering holds. `JoseonCore` does not import AppKit, Core Audio, or Metal. Renderers take frames. The app is the only place that wires capture, headphones, and windows. `Sources/JoseonApp/SPLWiring.swift` is an explicit seam for the SPL estimator. Measurement hardware is behind protocols in `MeasureSeams.swift`, with fakes for the self-check.

Swift 5 language mode means the compiler is not enforcing strict concurrency. Shared objects are `@unchecked Sendable` with comments that name the thread. That is maintainable as long as those comments stay true. `CONTRIBUTING.md` states a stricter rule than the code follows: "No allocation and no locks on the audio and analysis threads." The IO callback keeps to that rule on the paths below. The analysis queue does not. `AnalysisEngine.publish` takes `stateLock` (`NSLock`), `SpectrumAnalyzer.read` allocates a new `[Float]` per curve in `shaped` (`SpectrumAnalyzer.swift` around the `shaped` function), and `HeadphoneModel.evaluate` takes its own lock. The accurate contract is the one in `StereoRingBuffer` and `SpectrumAnalyzer`: the IO thread does not allocate or take an unbounded lock; `process` does not allocate once warm; `read` and frame publish may.

`docs/reviews/` is gitignored. Review notes dropped there will not be in the tree. This file lives under `docs/` on purpose.

### Concurrency: IO thread, analysis queue, UI

`SystemAudioTap` (`Sources/JoseonCapture/SystemAudioTap.swift`) names three threads: a serial `control` queue owns every Core Audio object, the IOProc touches only `RTState` raw pointers and the ring, and stream-info callbacks hop to the main queue. `start()` is synchronous and the file records that, with the permission prompt up, `AudioDeviceCreateIOProcIDWithBlock` has been seen not to return for about 90 seconds, and `stop()` then blocked for about the same time inside `AudioDeviceStop`. That figure is the author's note in the source, not a measurement from this review. The app does not call `start()` on the main thread: `AppModel.begin` uses `startAsync`, which runs `start()` on a global queue. `stop()` of the previous source runs on `lifecycleQueue`, so a prompt that is still up can stall that queue. It does not stall the UI.

The IO block (`makeIOBlock`) writes zeros into the aggregate's output buffers, deinterleaves into preallocated scratch (16,384 frames), and calls `ring.write`. It does not allocate, log, or touch `self`. Until the first non-zero sample it calls `vDSP_maxmgv`. Accelerate is not a documented real-time API; this call stops after the flag flips, so the steady state does not keep doing it. `signalFlag` and the diagnostic counters are plain aligned words written only from the IO thread. A cross-thread read of `counters` (`&+=`) is a data race in the Swift memory model. It is diagnostics only.

`StereoRingBuffer` is single-writer, single-reader, allocated once (default `1 << 17` frames). On macOS 15+ the writer is wait-free (`Atomic` exchange plus stores). On the deployment floor (macOS 14.4 through 14.x) `LockedRingSync` takes `os_unfair_lock` twice per write, around a few index words, never around the sample copy. The reader copies outside the lock and then `ringReaderCopyFence()` plus `claimEnd` rejects a copy the writer lapped. The comment on that fence says a concurrent stress test caught a torn read about once in thirty runs before the barrier existed. `RingBufferRaceTests` is the regression test. This is the right design for a process-tap callback.

`AnalysisEngine` ticks on `joseon.analysis` (user-interactive). It drains at most four reads of 32,768 frames per tick so a slow debug build cannot spin forever. After 0.25 s with no samples it feeds zeros so meters decay. After 4 s at the noise floor it sleeps and stops running the analyzers. `AppModel.supervise` (10 Hz, main) drops the tick to 10 Hz after 5 s of silence, 20 Hz for the menu-bar graph alone, and 60 Hz when a panel is visible, and turns stereo analysis off when nothing on screen needs it. `latestFrame` copies the frame under `NSLock`. Panels call that from the display link. The lock does not cover DSP, but it does sit on the path between the analysis queue and every panel.

Teardown order is sound: `AudioDeviceStop` returns after the last IO cycle, then scratch and `RTState` are freed (`teardownGraph`). The same pattern is in `MeasurementInputSession`. Display links are invalidated in `PanelView.deinit`. Update work uses a unique temp directory and deletes it with `defer`.

### Error handling

Capture failure falls back to the demo source and surfaces `captureError` (`AppModel.sourceDidStart`). The updater's failures are a typed enum shown in an alert. Measurement input throws `permissionNotGranted` and checks `AVCaptureDevice` authorization before any `AudioDeviceStart` (`MeasurementInput.start`). A bad headphone CSV is parsed before it is copied into Application Support (`HeadphoneLibrary.importCurve`).

Two gaps:

- Denied "System Audio Recording" does not fail the tap. The tap still returns `noErr` and delivers digital silence (`SystemAudioTap` header comment). The UI banner is a heuristic, and it is a coarser one than the tap's. `SystemAudioTap.isLikelyPermissionDenied` is silence for more than 3 s, some app playing, and the device not hogged. `AppModel.supervise` shows the banner on silence for more than 3 s while `activeSources` is non-empty, and never reads `isLikelyPermissionDenied` or `outputDeviceIsHogged`. Hog mode (exclusive DAC access, which the tap itself documents as a reason for silence) and a paused player that still holds an IO proc look like a denied permission. The probe prints the tap's flags (`JoseonProbe/main.swift`). The app does not use them.
- `Updater.check` and `Updater.install` discard the `URLResponse`. `URLSession` does not throw on an HTTP error status, so a non-200 body is treated as payload. The signature check still rejects a body that is not a valid Joseon app. A missing digest (below) is what makes the status check matter.

`MeasurementInputSession` can set the device nominal sample rate and wait up to 3 s. The measurement window passes `preferredSampleRate: nil` (`MeasureSeams.swift`), so the shipping path does not change the device rate. The setter remains on the type.

### Tests and blind spots

About 90 test files under `Tests/`, covering spectrum seams, loudness and true peak, the ring including a race test, session concurrency, SPL, measurement math, render layout, and the update JSON parser. `CONTRIBUTING.md` requires release-mode timing tests before a merge. Nothing in the repo runs them: there is no `.github/` workflow. `scripts/release.sh` is a local script. A merge can land without `swift test`.

Blind spots that follow from the layout, not from a failed run:

- No test opens a HAL device, by the contributing rule that tests must not play audio or open an input. Tap creation, aggregate-device format layout, permission silence, and device-switch rebuilds are untested outside a Mac with the entitlement.
- `Updater.unpackAndCheck` (checksum, `ditto`, team requirement, bundle version) has no test target. `UpdateFeedTests` covers JSON parsing only. The app target is an executable, so that logic is not in `JoseonCoreTests`.
- `PanelView.applyFrameRate` has no assertion that the display link's range equals `effectiveFramesPerSecond`. That is the bug in the next section.
- Render and Metal tests need a Mac GPU. They did not run here.

### Build and release hygiene

`scripts/bundle.sh` builds the release binary, copies `Info.plist` and the icon, and signs. `scripts/release.sh` re-signs with Developer ID, `--options runtime`, and a timestamp when an identity exists, zips with `ditto`, and notarizes only when passed `--notarize`. Publishing is a printed `gh` command, not an automatic step. Version is hand-edited `CFBundleShortVersionString` (`0.1.1` / build `2` in `scripts/Info.plist`).

`docs/details.html` (signing status) says the current public build has no Developer ID, so the first launch needs "Open Anyway", and that this build does not update itself. That matches the code: `checkSignature` rejects an empty team id, so an ad-hoc build cannot install an update. Hardened runtime is applied only in the Developer ID branch of `release.sh`. `bundle.sh` signs without `--options runtime`. An ad-hoc or Apple Development signature therefore has no hardened runtime.

`CONTRIBUTING.md` says Joseon is also distributed through the Mac App Store. The bundle has no App Sandbox entitlement. A process tap plus Accessibility is a hard fit for the App Store. The public install path described on the site is the dmg, not the store.

## 2. Performance

### Capture and the IO thread

Steady-state IO work is a copy into the ring plus, for interleaved tap buffers, a scalar deinterleave of at most 16,384 frames into scratch. No heap traffic on that path. The ring is 131,072 frames × 2 channels × 4 bytes = 1,048,576 bytes, allocated in `init`.

On macOS 15 and later the writer never waits on the analysis thread. On macOS 14 the writer can wait on `os_unfair_lock` for a few stores. Priority donation bounds that wait. It is still a lock on the real-time thread, which the type's own comment states. Most machines on macOS 15+ take the atomic path; 14.4 and 14.5 stay on the lock.

The scalar deinterleave is the obvious CPU knob if a high-rate interleaved device shows IO overruns. `vDSP` has a deinterleave. Nothing here measured an overrun.

### Analysis

`SpectrumAnalyzer` runs three Hann FFTs whose lengths at 48 kHz are 32,768, 8,192, and 2,048, with hops chosen so the long window refreshes at about 8.8 Hz and the short one at about 62.5 Hz (`SpectrumAnalyzer.swift` file header). Lengths scale with sample rate. `process` is specified to allocate only inside `configure`, which runs on the first block and when the rate or the display grid changes. `SpectrumPerformanceTests.testProcessDoesNotAllocateWhenWarm` checks the malloc zone. The same file's release-only assertions are: 800 frames at 48 kHz average under 1 ms, demo-signal `process` under 130 µs, `read` under 250 µs and under 30 µs on the demo path. Those assertions did not run in this review. They are the project's own bar, and they run only for `#if !DEBUG` (or the loose 4 ms debug cap).

`read` allocates nine display curves per call (`shaped` builds a new array each time: left, right, mid, side, peak hold, average, three mid layers) at `displayBins` (default 1,024, max 16,384). That is the analysis queue, once per tick, not the IO thread. At the panel rate that is about 60 publishes per second while music plays. Copy-on-write makes the UI's `latestFrame` copy cheap until the next publish replaces the arrays.

Silence is the battery path that is actually designed: engine sleep after 4 s at the floor, tick drop to 10 Hz, stereo filters skipped when only the menu bar is up. The file header on `analyzesStereo` says those 16 band filters are about a quarter of the analysis cost. That fraction was not remeasured here.

`SessionRecorder` keeps 1,800 one-second slots (30 minutes) of levels and events, not PCM. `ingest` is specified not to allocate once warm; a snapshot copies under `os_unfair_lock` after reserving outside the lock.

### Render loop

`PanelView` uses one `CAMetalDisplayLink` per panel, paused when the window is occluded, miniaturized, or hidden. A tick that sees the same `hostTime` and no animation skips the command buffer (`skippedFrameCount`). Spectrogram history is a GPU ring (`r16Unorm`, 1,200 × 1,024). New columns are a blit, not a full texture upload. The CPU mirror of that ring is 1,200 × 1,024 × 2 bytes = 2,457,600 bytes. Waterfall mode adds an R16 field texture, 160 bins by 160 rows, or 240 rows when the plot is wider than 1,200 pt (`waterfallLayoutChanged`), plus multisampled color and depth at the plot's pixel size. `waterfallAnimating` stays true while the resting camera sways.

The frame cap does not reach the link:

```177:179:Sources/JoseonRender/Panels.swift
    private func applyFrameRate() {
        let top = Float(effectiveFramesPerSecond)
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
    }
```

`effectiveFramesPerSecond` is `preferredFramesPerSecond` (30 for meters and spectrogram, 60 otherwise, at most 30 when Reduce Motion is on). `top` is unused. The link is asked for a preferred 120 Hz with a floor of 30 on every panel, on every display, including Reduce Motion. On a 60 Hz panel the system cannot exceed the screen. On a ProMotion display the link may run at 120 Hz. The skip path still avoids GPU work when the picture is static. It does not avoid the wake-up. While audio is playing, the spectrogram keeps `pendingCount > 0` as columns arrive (about one column per 16.7 ms at the default 20 s / 1,200 columns), so that panel encodes often. Waterfall sway sets `isAnimating` continuously unless Reduce Motion is on or the user has orbited the camera. Each visible panel has its own link, so the main thread wakes once per panel per refresh.

`inFlight` caps outstanding command buffers at `FrameArena.inFlight`. Completion handlers hop to the main queue to drop the count. A stalled main thread drops frames rather than queuing without bound. `lastGPUFrameTime` is recorded and not otherwise used to adapt the rate.

### What was not measured

No Instruments trace, no `swift test -c release`, no energy log. Do not treat the test budgets above as numbers from this review. The frame-rate bug is visible in the source without a profile: the value that was supposed to cap the link is discarded.

## 3. Security and privacy

Ranked by what a person can actually do to a user of this local app. There is no network service in the app, no embedded secret, and no third-party package (`Package.swift` has no `.package`). A search of the tree found no keys, tokens, or private keys.

### 1. The public build is unsigned, and the site tells people to bypass Gatekeeper

`docs/details.html` states that the current macOS build has no Developer ID and that the first launch is allowed with "Open Anyway". `docs/index.html` repeats that step. `docs/site/page.js` then sets the download button's `href` to `asset.browser_download_url` from the GitHub releases API, with no host allowlist and no checksum on the page. The asset name and size are shown. The SHA-256, which `details.html` says is on the release page, is not.

Realistic attack: a stolen GitHub account, or any path that can replace `Joseon-v*-macos.dmg` on `jasas1/Joseon`, ships a disk image to people who have been taught to dismiss the Gatekeeper warning. There is no notarization ticket and no hardened runtime on that ad-hoc path (`release.sh` notarizes only with `--notarize`, and only after a Developer ID sign). This is the highest-probability issue because it matches how the app is distributed today. It is a supply-chain and signing gap, not a memory-corruption bug.

### 2. The updater's digest check is optional, and the docs say it is mandatory

`SECURITY.md` and `docs/details.html` say an update is accepted only when its SHA-256 matches the release. `UpdateFeed.newestRelease` sets `sha256` only when the asset's `digest` starts with `sha256:`. `UpdateFeedTests` expects `nil` when the field is absent. `Updater.unpackAndCheck` skips the hash when `release.sha256` is nil:

```97:100:Sources/JoseonApp/Updater.swift
        if let wanted = release.sha256 {
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard digest == wanted else { throw Failure.checksum }
        }
```

What still holds, and is the real control:

- Asset URL must start with `https://github.com/jasas1/` (or `file:///` when `JOSEON_UPDATE_FEED` is set).
- `SecStaticCodeCheckValidity` with `kSecCSStrictValidate`, all architectures, and nested code. The requirement string pins the identifier `app.joseon.Joseon` and `certificate leaf[subject.OU]` to this app's team id.
- The team id is required to be non-empty and alphanumeric before it is interpolated, so the requirement string cannot be broken out of.
- `CFBundleShortVersionString` of the unpacked app must equal the release tag.
- An ad-hoc build has no team and refuses every update.
- Automatic checks default on (`checkUpdatesAutomatically` registered as true) and can be turned off. The only `URLSession` in the app is this updater. The request sends a `User-Agent` of `Joseon/<version>` and no body.

What does not hold:

- A release asset with no `digest` installs on signature alone.
- `URLSession.shared.download` follows redirects. The prefix is checked on the URL in the JSON, not on the final response URL, and the HTTP status is ignored.
- The validity flags do not require a notarization ticket. A Developer ID signature from the same team is enough, including one Apple has not notarized.
- The zip is extracted with `/usr/bin/ditto` into a temp directory before the signature check. Only `Joseon.app` is swapped into place, and the temp directory is removed afterwards. A path inside the archive that `ditto` writes outside that directory would land before the signature is checked. This review did not prove that current `ditto` honors `..`. Treat it as hardening, not as a demonstrated bypass.
- `JOSEON_UPDATE_FEED` plus `JOSEON_UPDATE_ACCEPT=1` installs without the alert and allows `file:///` URLs. The signature check stays. An attacker who can set the environment of an already-signed app still needs a binary signed by that team. Low, local.

Until a Developer ID build exists, finding 1 dominates, because self-update is off. The day `release.sh` signs with a team id, finding 2 becomes the update path. Fix the digest, the status code, and the redirect host before that build ships.

The relaunch helper is `/bin/sh -c` with the pid interpolated (an integer) and the bundle path passed as `$0`, not spliced into the script. That part is fine.

### 3. The project page writes release fields into HTML

`docs/site/page.js` `fillDownload` does:

```javascript
link.href = asset.browser_download_url;
meta.innerHTML = `...${rel.tag_name}... <a href="${rel.html_url}">notes</a>`;
```

`tag_name` and `html_url` are inserted as HTML. Git ref rules allow `<`, `>`, and `"` in a tag. A release published to `jasas1/Joseon` or `jasas1/JoseonPC` can run script in the browser of anyone who opens the GitHub Pages site, and can point the download button at whatever `browser_download_url` the API returns. The page caches the JSON in `sessionStorage` for 10 minutes. Scripts are same-origin; the page loads no third-party script. The microphone and file buttons in `groove.js` stay in the tab: `getUserMedia` is not connected to the speakers, and `decodeAudioData` does not upload. That part matches the footer.

This needs the ability to publish a release. It is the same account as finding 1, with a browser impact on visitors who never install the app. Ranked under the unsigned dmg because the dmg is the direct code-execution path.

### 4. Accessibility is requested by default and is missing from the privacy statement

`showNowPlaying` is registered as `true` (`AppSettings.swift`). On launch, `applyNowPlaying` explains once and then calls `AXIsProcessTrustedWithOptions` with the prompt (`AccessibilityNowPlayingReader.requestTrust`). The reader only walks Qobuz (`com.qobuz.desktop`) and sets `AXManualAccessibility` on that process. The permission macOS grants is not limited to Qobuz. After the user allows it, this process can read other applications' accessibility trees. `SECURITY.md` lists the microphone, the one GitHub request, and the audio-input entitlement. It does not mention Accessibility. `NSAudioCaptureUsageDescription` and `NSMicrophoneUsageDescription` are present in `scripts/Info.plist`. There is no separate usage string for Accessibility; macOS uses the system prompt.

The microphone path is in better shape: `MeasurementInput.start` throws unless status is already `.authorized`, and only a click in the measurement window calls `request`. The recording is specified to stay in memory; the saved artifact is a CSV curve under `~/Library/Application Support/Joseon/Curves`.

System audio is a copy of the mix (`CATapDescription`, `muteBehavior = .unmuted`, private tap, empty exclude list). That includes every app, not only the music player. Samples live in the ring and are overwritten. `SessionRecorder` stores levels and events. The noise-dose ledger is a third on-disk item, `UserDefaults` key `spl.doseLedger.v1` (`UserDefaultsDoseStore`), which `SECURITY.md` does not list. It is exposure totals, not audio.

### 5. Sandbox, hardened runtime, entitlements

`scripts/Joseon.entitlements` contains only `com.apple.security.device.audio-input`. There is no `com.apple.security.app-sandbox`. Without the sandbox that key does not confine the process; microphone TCC still comes from the usage string and `AVCaptureDevice`. An unsandboxed process that the user has trusted with system-audio capture and Accessibility has the user's files and can spawn `ditto` and `sh`, which the updater does. For a process-tap utility this is the usual shape. It means a compromised build is a full user-level agent, which is why findings 1 and 2 are ranked first.

Hardened runtime (library validation, restricted `DYLD_*`) applies only to the Developer ID re-sign. The audio-input entitlement is the one hardened runtime expects for the microphone. No ATS exceptions are in `Info.plist`, so cleartext HTTP is off. No other outbound host appears in app Swift sources.

### 6. Dependencies and secrets

No Swift package dependencies. AutoEQ curves are source, documented in `docs/third-party-autoeq.md` and `NOTICE`. No credentials in the tree. Residual risk is Apple's frameworks plus `/usr/bin/ditto` and `/bin/sh` at update time.

### Privacy claim check

| Claim in `SECURITY.md` / `details.html` | What the code does |
|---|---|
| One network call, the GitHub release list | True of the app. The Pages script also calls `api.github.com` for both repos. |
| Update requires a matching SHA-256 | True only when the asset JSON includes `digest`. |
| Audio is not written to disk | True of PCM. Dose totals and curves and settings are written. |
| Microphone only after a measurement click | True. |
| One entitlement, audio input | True of the plist. Accessibility is a separate TCC grant, requested by default, and is not in that sentence. |
| Current macOS build does not self-update | True while the running binary has no team id. |

## 4. Parity with JoseonPC

Not a review of the Rust tree. From this repo's `docs/details.html` and the public GitHub page for `jasas1/JoseonPC`:

- The site presents the same panels on both platforms. This repo's macOS tree has the waterfall spectrogram, session timeline, and measurement window in Swift. Whether the Windows tree has caught up to the waterfall commits was not checked.
- `details.html` says Windows releases are built on GitHub Actions (`.github/workflows/release.yml` in that repo) and that every release lists SHA-256. This repository has no `.github/` directory. macOS release is `scripts/release.sh` on a developer machine.
- The same page says the Windows updater checks SHA-256 and the macOS updater also checks the signature. The macOS signature check is real. The macOS SHA-256 check is conditional, as above.
- Both public builds are described as unsigned, with a first-launch bypass ("Open Anyway" / SmartScreen "Run anyway").

## Prioritized fixes

1. Sign and notarize the dmg that the project page links to, and stop instructing a Gatekeeper bypass once that exists. Until then, show the SHA-256 beside the download button and link to the release notes rather than only to `browser_download_url`.
2. In `Updater.unpackAndCheck`, require a `sha256:` digest, reject any other, and refuse the download when the HTTP status is not 200 or the final URL host is not GitHub's. Check those before `ditto`. Add a notarization requirement to the `SecStaticCode` flags when releases are notarized. Cover this with a test that does not need a real signature (missing digest, bad status, bad prefix).
3. In `docs/site/page.js`, escape `tag_name` and `html_url` (text and attribute), and accept `browser_download_url` only when its host is `github.com` or `release-assets.githubusercontent.com` (or the host GitHub actually returns for these assets).
4. Pass `effectiveFramesPerSecond` into `CAFrameRateRange` in `PanelView.applyFrameRate`. Keep the early-out, but the link should not prefer 120 Hz when the panel asked for 30 or Reduce Motion is on.
5. Drive the permission banner from `SystemAudioTap.isLikelyPermissionDenied`, and show hog mode as its own message. Default `showNowPlaying` to off, or ask for Accessibility only from a control the user turns on. Add Accessibility and the dose ledger to `SECURITY.md`.
6. Add a CI job that runs `swift test` on macOS. Run the release-mode performance tests when DSP in `JoseonCore` changes. They already exist; nothing invokes them.
