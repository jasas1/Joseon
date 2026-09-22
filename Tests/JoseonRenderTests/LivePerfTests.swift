import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// Live CPU cost of four panels in a real window. Off by default: set JOSEON_LIVE_PERF=1.
/// Prints `LIVEPERF` lines: process CPU seconds (user + system, all threads) per wall second.
final class LivePerfTests: XCTestCase {
    private static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    func testFourPanelsLiveCPU() throws {
        guard ProcessInfo.processInfo.environment["JOSEON_LIVE_PERF"] == "1" else { throw XCTSkip("Set JOSEON_LIVE_PERF=1") }
        try RenderTestSupport.requireMetal()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        PanelView.ignoresOcclusionForTesting = true
        defer { PanelView.ignoresOcclusionForTesting = false }

        var o = SyntheticFrames.Options()
        o.includeHeadphone = true
        let frames = SyntheticFrames.sequence(count: 600, options: o)
        var index = 0
        var latest = frames[0]
        let provider: FrameProvider = { latest }
        let views: [PanelView] = [SpectrumView(frameProvider: provider), SpectrogramView(frameProvider: provider),
                                  VectorscopeView(frameProvider: provider), MetersView(frameProvider: provider)]
        // Essential layout: spectrum on top, three cards below.
        let window = NSWindow(contentRect: CGRect(x: 60, y: 60, width: 1280, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800))
        views[0].frame = CGRect(x: 0, y: 360, width: 1280, height: 440)
        for i in 1..<4 { views[i].frame = CGRect(x: CGFloat(i - 1) * 427, y: 0, width: 426, height: 360) }
        views.forEach(content.addSubview)
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating       // an occluded window gets about 3 callbacks per second: keep it on top for the measurement
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        // Analysis frames arrive at 60 Hz, like the engine.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            index += 1
            var f = frames[index % frames.count]
            f.hostTime = Double(index) / 60
            latest = f
        }
        RunLoop.main.add(timer, forMode: .common)

        RunLoop.main.run(until: Date().addingTimeInterval(2))     // warm up
        let seconds = 6.0
        let c0 = Self.cpuSeconds(), n0 = views.map(\.drawnFrameCount), t0 = CFAbsoluteTimeGetCurrent()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        let wall = CFAbsoluteTimeGetCurrent() - t0
        let cpu = Self.cpuSeconds() - c0
        let fps = zip(views.map(\.drawnFrameCount), n0).map { Double($0 - $1) / wall }
        print(String(format: "LIVEPERF panels cpu %.1f %% of one core  fps %@  visible %@", cpu / wall * 100,
                     fps.map { String(format: "%.0f", $0) }.joined(separator: "/"), window.occlusionState.contains(.visible) ? "yes" : "no"))

        for v in views { print("LIVEPERF state \(v.kind.rawValue): \(v.debugRunState)") }

        // The same loop with the panels paused: the cost of the harness itself.
        views.forEach { $0.isPaused = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let c1 = Self.cpuSeconds(), t1 = CFAbsoluteTimeGetCurrent()
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        print(String(format: "LIVEPERF paused cpu %.1f %% of one core", (Self.cpuSeconds() - c1) / (CFAbsoluteTimeGetCurrent() - t1) * 100))
        timer.invalidate()
        window.close()
    }
}
