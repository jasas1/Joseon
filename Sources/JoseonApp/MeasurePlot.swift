import SwiftUI
import JoseonCore
import JoseonHeadphones

// The plots of the measurement window: SwiftUI `Canvas`, log frequency 20 Hz … 20 kHz. Nothing here touches JoseonRender.

struct MeasurePlotSeries: Identifiable {
    enum Style { case solid, dashed, dotted }
    var id: String
    var title: String
    var color: Color
    var style: Style
    var lineWidth: CGFloat
    var frequenciesHz: [Float]
    var levelsDB: [Float]
}

enum MeasurePlotColors {
    static let left = Color(red: 0.40, green: 0.78, blue: 1.0)
    static let right = Color(red: 1.0, green: 0.55, blue: 0.45)
    static let average = Color.white
    static let autoEq = Color(red: 0.98, green: 0.80, blue: 0.35)
    static let target = Color(white: 0.62)
}

/// Frequency responses, all 0 dB at 1 kHz. The zone under `lowestHonestHz` is shaded and labelled.
struct MeasureResponsePlot: View {
    var series: [MeasurePlotSeries]
    var lowestHonestHz: Double?
    var summary: String

    private static let lowHz = 20.0, highHz = 20_000.0
    private static let gridHz: [Double] = [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]

    /// A range in 5 dB steps that holds every curve inside 30 Hz … 16 kHz, at least −15 … +10.
    private var range: ClosedRange<Double> {
        var low = -15.0, high = 10.0
        for s in series {
            for (f, v) in zip(s.frequenciesHz, s.levelsDB) where f >= 30 && f <= 16_000 && v.isFinite {
                low = min(low, Double(v)); high = max(high, Double(v))
            }
        }
        return max(-40, (low / 5).rounded(.down) * 5) ... min(30, (high / 5).rounded(.up) * 5)
    }

    static func label(_ hz: Double) -> String { hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))" }

    var body: some View {
        let range = self.range
        Canvas { context, size in
            let left: CGFloat = 34, bottom: CGFloat = 18, top: CGFloat = 6, right: CGFloat = 8
            let plot = CGRect(x: left, y: top, width: max(10, size.width - left - right), height: max(10, size.height - top - bottom))
            func x(_ hz: Double) -> CGFloat { plot.minX + plot.width * CGFloat(log(max(hz, 1) / Self.lowHz) / log(Self.highHz / Self.lowHz)) }
            func y(_ db: Double) -> CGFloat { plot.maxY - plot.height * CGFloat((db - range.lowerBound) / (range.upperBound - range.lowerBound)) }

            context.fill(Path(roundedRect: plot, cornerRadius: 4), with: .color(Color.black.opacity(0.22)))

            // Grid and labels.
            let gridColor = Color.white.opacity(0.10)
            for hz in Self.gridHz {
                var p = Path(); p.move(to: CGPoint(x: x(hz), y: plot.minY)); p.addLine(to: CGPoint(x: x(hz), y: plot.maxY))
                context.stroke(p, with: .color(gridColor), lineWidth: 1)
                context.draw(Text(Self.label(hz)).font(.system(size: 9.5)).foregroundColor(Color.joseonSecondary),
                             at: CGPoint(x: min(max(x(hz), plot.minX + 8), plot.maxX - 8), y: plot.maxY + 9))
            }
            var db = range.lowerBound
            while db <= range.upperBound + 0.01 {
                var p = Path(); p.move(to: CGPoint(x: plot.minX, y: y(db))); p.addLine(to: CGPoint(x: plot.maxX, y: y(db)))
                context.stroke(p, with: .color(db == 0 ? Color.white.opacity(0.28) : gridColor), lineWidth: 1)
                context.draw(Text(NumberText.signed(Int(db))).font(.system(size: 9.5).monospacedDigit()).foregroundColor(Color.joseonSecondary),
                             at: CGPoint(x: plot.minX - 5, y: y(db)), anchor: .trailing)
                db += 5
            }

            // Under the lowest honest frequency the curve is the window and the noise, not the headphone.
            if let honest = lowestHonestHz, honest > Self.lowHz {
                let edge = x(min(honest, Self.highHz))
                let zone = CGRect(x: plot.minX, y: plot.minY, width: edge - plot.minX, height: plot.height)
                context.fill(Path(zone), with: .color(Color.joseonWarn.opacity(0.13)))
                var p = Path(); p.move(to: CGPoint(x: edge, y: plot.minY)); p.addLine(to: CGPoint(x: edge, y: plot.maxY))
                context.stroke(p, with: .color(Color.joseonWarn.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                context.draw(Text("not reliable under \(Int(honest.rounded())) Hz").font(.system(size: 9.5, weight: .medium)).foregroundColor(Color.joseonWarn),
                             at: CGPoint(x: edge + 4, y: plot.minY + 8), anchor: .leading)
            }

            context.clip(to: Path(plot))
            for s in series {
                var path = Path()
                var started = false
                for (f, v) in zip(s.frequenciesHz, s.levelsDB) where Double(f) >= Self.lowHz && Double(f) <= Self.highHz && v.isFinite {
                    let point = CGPoint(x: x(Double(f)), y: y(Double(v)))
                    if started { path.addLine(to: point) } else { path.move(to: point); started = true }
                }
                let dash: [CGFloat] = s.style == .solid ? [] : (s.style == .dashed ? [6, 4] : [2, 3])
                context.stroke(path, with: .color(s.color), style: StrokeStyle(lineWidth: s.lineWidth, lineCap: .round, lineJoin: .round, dash: dash))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Frequency response plot, 20 hertz to 20 kilohertz, levels relative to 1 kilohertz")
        .accessibilityValue(summary)
    }
}

/// One legend entry: a line sample in the series' color and style, and its name.
struct MeasureLegendItem: View {
    var series: MeasurePlotSeries

    var body: some View {
        HStack(spacing: 5) {
            Canvas { context, size in
                var p = Path(); p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                let dash: [CGFloat] = series.style == .solid ? [] : (series.style == .dashed ? [6, 4] : [2, 3])
                context.stroke(p, with: .color(series.color), style: StrokeStyle(lineWidth: max(1.5, series.lineWidth), dash: dash))
            }
            .frame(width: 22, height: 8)
            .accessibilityHidden(true)
            Text(series.title).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// The correction of a calibration file, 20 Hz … 20 kHz, with its range in dB next to it.
struct MeasureSparkline: View {
    var values: [Double]
    var caption = ""

    var body: some View {
        let low = values.min() ?? 0, high = values.max() ?? 0
        HStack(spacing: 8) {
            Canvas { context, size in
                let span = max(high - low, 1)
                var zero = Path()
                let zeroY = size.height - size.height * CGFloat((0 - low) / span)
                if zeroY >= 0, zeroY <= size.height {
                    zero.move(to: CGPoint(x: 0, y: zeroY)); zero.addLine(to: CGPoint(x: size.width, y: zeroY))
                    context.stroke(zero, with: .color(Color.white.opacity(0.22)), lineWidth: 1)
                }
                var path = Path()
                for (i, v) in values.enumerated() {
                    let point = CGPoint(x: size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                                        y: (size.height - 2) - (size.height - 4) * CGFloat((v - low) / span) + 1)
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(Color.joseonAccent), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
            .frame(width: 150, height: 30)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.22)))
            VStack(alignment: .leading, spacing: 2) {
                if !caption.isEmpty { Text(caption) }
                Text("Correction 20 Hz – 20 kHz: \(NumberText.signed(low, decimals: 1)) … \(NumberText.signed(high, decimals: 1)) dB")
            }
            .font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.joseonSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Correction curve")
        .accessibilityValue("From \(NumberText.signed(low, decimals: 1)) to \(NumberText.signed(high, decimals: 1)) decibels between 20 hertz and 20 kilohertz")
    }
}

/// Input level: −60 … 0 dBFS, the target zone for the peak, the highest peak so far, and the clip light.
struct MeasureInputMeter: View {
    var meter: MeasureMeter
    /// Highest input peak of the last finished check, shown while nothing runs.
    var heldPeakDB: Double?
    var heldClipped: Bool

    private static let floorDB = -60.0
    private func share(_ db: Double) -> CGFloat { CGFloat(min(max((db - Self.floorDB) / -Self.floorDB, 0), 1)) }

    var body: some View {
        let clipped = meter.clipped || heldClipped
        let marker = meter.maxPeakDB.isFinite ? meter.maxPeakDB : heldPeakDB
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { proxy in
                    let w = proxy.size.width
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.3))
                        // Target zone for the input peak.
                        Rectangle().fill(Color(nsColor: Palette.live).opacity(0.28))
                            .frame(width: w * (share(MeasureSignal.inputTargetDBFS.upperBound) - share(MeasureSignal.inputTargetDBFS.lowerBound)))
                            .offset(x: w * share(MeasureSignal.inputTargetDBFS.lowerBound))
                        if meter.peakDB.isFinite {
                            RoundedRectangle(cornerRadius: 3).fill(clipped ? Color.joseonDanger : Color.joseonAccent)
                                .frame(width: max(3, w * share(meter.peakDB)))
                        }
                        if let marker, marker.isFinite {
                            Rectangle().fill(Color.white).frame(width: 2).offset(x: max(0, w * share(marker) - 1))
                        }
                    }
                }
                .frame(height: 12)
                // The scale sits under the bar it belongs to: the ends, and the target zone under the green band.
                GeometryReader { proxy in
                    let w = proxy.size.width
                    let zoneLow = w * share(MeasureSignal.inputTargetDBFS.lowerBound), zoneHigh = w * share(MeasureSignal.inputTargetDBFS.upperBound)
                    ZStack(alignment: .topLeading) {
                        Text("\(NumberText.signed(Int(Self.floorDB))) dBFS")
                        Text("target \(NumberText.signed(Int(MeasureSignal.inputTargetDBFS.lowerBound))) … \(NumberText.signed(Int(MeasureSignal.inputTargetDBFS.upperBound)))")
                            .foregroundStyle(Color(nsColor: Palette.live))
                            .fixedSize()
                            .frame(width: zoneHigh - zoneLow)
                            .offset(x: zoneLow)
                        Text("0").frame(width: w, alignment: .trailing)
                    }
                }
                .frame(height: 13)
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(Color.joseonSecondary)
            }
            Text("CLIP")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(clipped ? Color.white : Color.joseonSecondary.opacity(0.6))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(clipped ? Color.joseonDanger : Color.black.opacity(0.3)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input level")
        .accessibilityValue(clipped ? "Clipped" : (marker.map { "Highest peak \(Int($0.rounded())) dBFS" } ?? "No signal"))
    }
}
