import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// Display-independent cost of the panel work: four panels (Essential layout sizes), 60 analysis frames per second for
/// 5 s of wall time, every tick does what the view does except presenting a drawable. Works with a locked screen.
/// Set JOSEON_TICK_COST=1. Prints process CPU (user + system) as a share of one core.
final class TickCostTests: XCTestCase {
    private static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    private static func threadCPU() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }

    func testTickCost() throws {
        guard ProcessInfo.processInfo.environment["JOSEON_TICK_COST"] == "1" else { throw XCTSkip("Set JOSEON_TICK_COST=1") }
        try RenderTestSupport.requireMetal()
        var o = SyntheticFrames.Options()
        o.includeHeadphone = true
        // JOSEON_TICK_SPL=1: frames with an SPL reading, the spectrum on the dB SPL axis (the cost of "Level at the ear").
        let withSPL = ProcessInfo.processInfo.environment["JOSEON_TICK_SPL"] == "1"
        o.includeSPL = withSPL
        var spectrumSettings = OffscreenRenderer.Settings()
        if withSPL { spectrumSettings.levelAxis = .dBSPL }
        let frames = SyntheticFrames.sequence(count: 600, options: o)
        let sizes: [(PanelKind, CGSize)] = [(.spectrum, CGSize(width: 1280, height: 440)), (.spectrogram, CGSize(width: 426, height: 360)),
                                            (.vectorscope, CGSize(width: 426, height: 360)), (.meters, CGSize(width: 426, height: 360))]
        let sessions = try sizes.map { try OffscreenRenderer.Session(panel: $0.0, size: $0.1, scale: 2, theme: Theme(), settings: $0.0 == .spectrum ? spectrumSettings : .init()) }
        for s in sessions { try s.feed(Array(frames.prefix(60))) }
        // JOSEON_TICK_CURSOR=1: a linked cursor that moves on every tick (a sweep over the axis, 3.2 s back in time), with the
        // spectrogram's column published to the spectrum at most 30 times per second, as the views do it.
        // JOSEON_TICK_CURSOR=linked: the panels are linked but there is no cursor (the cost of the link alone).
        let cursorMode = ProcessInfo.processInfo.environment["JOSEON_TICK_CURSOR"] ?? ""
        let movingCursor = cursorMode == "1"
        if movingCursor || cursorMode == "linked" { for s in sessions { s.renderer.cursorLinked = true } }
        var lastColumn: Int?
        let seconds = 5.0
        let c0 = Self.cpuSeconds(), t0 = CFAbsoluteTimeGetCurrent()
        let misses0 = OverlayContext.lineCacheMisses
        var tick = 0
        // Where the main thread's CPU time goes (thread CPU clock: not inflated by waiting, less by a busy machine).
        var ingestCPU = 0.0, textCPU = 0.0, encodeCPU = 0.0
        var textRedraws = 0
        var redrawCPU = [Double](repeating: 0, count: 4), redrawCount = [Int](repeating: 0, count: 4), idleTextCPU = 0.0
        let redraws0 = sessions.map { $0.renderer.textLayer.redrawCount }
        while CFAbsoluteTimeGetCurrent() - t0 < seconds {
            let due = t0 + Double(tick + 1) / 60
            var f = frames[tick % frames.count]
            f.hostTime = 10 + Double(tick) / 60
            if movingCursor {
                let hz = Float(100 * pow(100.0, Double(tick % 120) / 120))
                let c = PanelCursor(frequencyHz: hz, secondsAgo: 3.2, source: .spectrogram)
                for s in sessions { s.renderer.cursor = c }
                if tick % 2 == 0, let g = sessions[1].renderer as? SpectrogramRenderer, let id = g.historyColumnID(secondsAgo: 3.2), id != lastColumn {
                    lastColumn = id
                    let slice = g.historyColumn(secondsAgo: 3.2)?.slice
                    for s in sessions { s.renderer.cursorSlice = slice }
                }
            }
            for (i, s) in sessions.enumerated() {
                // New code: spectrum and vectorscope at 60 fps, spectrogram and meters at 30 (their default cap).
                let everyTick = i == 0 || i == 2
                let a = Self.threadCPU()
                s.renderer.ingest(f)
                let b = Self.threadCPU()
                let redrew = s.renderer.refreshText(now: f.hostTime)          // at most 10 Hz inside, only on change
                let c = Self.threadCPU()
                ingestCPU += b - a; textCPU += c - b
                if redrew { redrawCPU[i] += c - b; redrawCount[i] += 1 } else { idleTextCPU += c - b }
                guard everyTick || tick % 2 == 0, let cb = s.ctx.queue.makeCommandBuffer() else { continue }
                s.renderer.encode(commandBuffer: cb, target: s.target)
                cb.commit()
                encodeCPU += Self.threadCPU() - c
            }
            tick += 1
            let wait = due - CFAbsoluteTimeGetCurrent()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
        let wall = CFAbsoluteTimeGetCurrent() - t0
        print("TICKCOST text per redraw: " + zip(sizes, zip(redrawCPU, redrawCount)).map { String(format: "%@ %.3f ms x %d", $0.0.0.rawValue, $0.1.0 / Double(max($0.1.1, 1)) * 1000, $0.1.1) }.joined(separator: ", ")
              + String(format: "; calls without a redraw %.3f %% of one core; %d lines typeset", idleTextCPU / (CFAbsoluteTimeGetCurrent() - t0) * 100, OverlayContext.lineCacheMisses - misses0))
        for (s, r0) in zip(sessions, redraws0) { textRedraws += s.renderer.textLayer.redrawCount - r0 }
        print(String(format: "TICKCOST main thread, %% of one core: ingest %.2f, text %.2f (%d redraws), encode + commit %.2f. The rest of the total is Metal driver and completion threads.",
                     ingestCPU / wall * 100, textCPU / wall * 100, textRedraws, encodeCPU / wall * 100))
        print("TICKCOST cursor: " + (movingCursor ? "linked, moving on every tick, timed (ghost trace)" : (cursorMode == "linked" ? "linked, no cursor" : "not linked")))
        print(String(format: "TICKCOST %@: %.2f %% of one core over %.1f s, %d ticks", withSPL ? "with SPL reading, dB SPL axis" : "round 5 (60/30 fps caps, GPU text at 10 Hz, changed items only)", (Self.cpuSeconds() - c0) / wall * 100, wall, tick))
    }
}
