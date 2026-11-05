import SwiftUI

struct ChartSeries {
    var label: String
    var values: [Double]
    var color: Color
}

private extension Array where Element == Double {
    /// Value `back` samples before the newest one, if present.
    func value(back: Int) -> Double? {
        let i = count - 1 - back
        return indices.contains(i) ? self[i] : nil
    }
}

/// Shared geometry: newest sample sits at the right edge, one slot per sample.
private struct TimeAxis {
    let width: CGFloat
    var step: CGFloat { width / CGFloat(Series.capacity - 1) }
    func x(back: Int) -> CGFloat { width - CGFloat(back) * step }
    func back(at x: CGFloat) -> Int {
        guard step > 0, x.isFinite else { return 0 }
        return max(0, min(Series.capacity - 1, Int(((width - x) / step).rounded())))
    }
}

/// Area chart over the last two minutes. `stacked` draws series cumulatively (first = bottom).
struct AreaChart: View {
    var series: [ChartSeries]
    var range: ClosedRange<Double> = 0...1
    var stacked = false
    var height: CGFloat = 64
    var interval: Double
    var format: (Double) -> String

    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let axis = TimeAxis(width: geo.size.width)
            Canvas { ctx, size in
                drawGrid(ctx, size)
                var floor = [Double](repeating: range.lowerBound, count: Series.capacity)
                for s in series {
                    let count = s.values.count
                    guard count > 1 else { continue }
                    var tops: [CGPoint] = []
                    var bottoms: [CGPoint] = []
                    for back in 0..<count {
                        let v = s.values[count - 1 - back]
                        let base = stacked ? floor[back] : range.lowerBound
                        let top = stacked ? base + max(0, v - range.lowerBound) : v
                        if stacked { floor[back] = top }
                        tops.append(CGPoint(x: axis.x(back: back), y: y(top, size)))
                        bottoms.append(CGPoint(x: axis.x(back: back), y: y(base, size)))
                    }
                    var area = Path()
                    area.addLines(tops)
                    area.addLines(bottoms.reversed())
                    area.closeSubpath()
                    ctx.fill(area, with: .linearGradient(
                        Gradient(colors: [s.color.opacity(stacked ? 0.45 : 0.40), s.color.opacity(stacked ? 0.30 : 0.04)]),
                        startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
                    var line = Path()
                    line.addLines(tops)
                    ctx.stroke(line, with: .color(s.color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
                drawBaseline(ctx, size)
            }
            .overlay(alignment: .topLeading) { hoverOverlay(axis: axis, size: geo.size) }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hoverX = p.x } else { hoverX = nil }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(series.map { "\($0.label) \(format($0.values.last ?? 0))" }.joined(separator: ", "))
    }

    private func y(_ v: Double, _ size: CGSize) -> CGFloat {
        let span = max(range.upperBound - range.lowerBound, .ulpOfOne)
        let f = (min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span
        return size.height * (1 - CGFloat(f))
    }

    private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize) {
        for f in [0.25, 0.5, 0.75] {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: size.height * f))
            p.addLine(to: CGPoint(x: size.width, y: size.height * f))
            ctx.stroke(p, with: .color(Palette.grid), lineWidth: 1)
        }
    }

    private func drawBaseline(_ ctx: GraphicsContext, _ size: CGSize) {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: size.height - 0.5))
        p.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
        ctx.stroke(p, with: .color(Palette.baseline), lineWidth: 1)
    }

    @ViewBuilder
    private func hoverOverlay(axis: TimeAxis, size: CGSize) -> some View {
        if let hoverX {
            let back = axis.back(at: hoverX)
            let rows = series.reversed().compactMap { s in s.values.value(back: back).map { (s.label, s.color, format($0)) } }
            if !rows.isEmpty {
                HoverReadout(x: axis.x(back: back), size: size, rows: rows,
                             footer: Fmt.secondsAgo(Double(back) * interval))
            }
        }
    }
}

/// Two series mirrored around a centre line (e.g. download above, upload below),
/// each half scaled to its own recent peak so small values stay visible.
struct MirrorChart: View {
    var top: ChartSeries
    var bottom: ChartSeries
    var floor: Double = 10_000
    var height: CGFloat = 76
    var interval: Double
    var format: (Double) -> String

    @State private var hoverX: CGFloat?

    var body: some View {
        let topMax = max(floor, top.values.max() ?? 0) * 1.1
        let bottomMax = max(floor, bottom.values.max() ?? 0) * 1.1
        GeometryReader { geo in
            let axis = TimeAxis(width: geo.size.width)
            Canvas { ctx, size in
                let mid = size.height / 2
                for f in [0.25, 0.75] {
                    var g = Path()
                    g.move(to: CGPoint(x: 0, y: size.height * f))
                    g.addLine(to: CGPoint(x: size.width, y: size.height * f))
                    ctx.stroke(g, with: .color(Palette.grid), lineWidth: 1)
                }
                draw(ctx, top, axis: axis, mid: mid, extent: -mid, peak: topMax, size: size)
                draw(ctx, bottom, axis: axis, mid: mid, extent: mid, peak: bottomMax, size: size)
                var m = Path()
                m.move(to: CGPoint(x: 0, y: mid))
                m.addLine(to: CGPoint(x: size.width, y: mid))
                ctx.stroke(m, with: .color(Palette.baseline), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) { ScaleLabel(text: format(topMax / 1.1)) }
            .overlay(alignment: .bottomLeading) { ScaleLabel(text: format(bottomMax / 1.1)) }
            .overlay(alignment: .topLeading) {
                if let hoverX {
                    let back = axis.back(at: hoverX)
                    let rows = [top, bottom].compactMap { s in s.values.value(back: back).map { (s.label, s.color, format($0)) } }
                    if !rows.isEmpty {
                        HoverReadout(x: axis.x(back: back), size: geo.size, rows: rows,
                                     footer: Fmt.secondsAgo(Double(back) * interval))
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hoverX = p.x } else { hoverX = nil }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("\(top.label) \(format(top.values.last ?? 0)), \(bottom.label) \(format(bottom.values.last ?? 0))")
    }

    private func draw(_ ctx: GraphicsContext, _ s: ChartSeries, axis: TimeAxis, mid: CGFloat, extent: CGFloat, peak: Double, size: CGSize) {
        let count = s.values.count
        guard count > 1 else { return }
        var points: [CGPoint] = []
        for back in 0..<count {
            let v = s.values[count - 1 - back]
            points.append(CGPoint(x: axis.x(back: back), y: mid + extent * CGFloat(min(1, v / peak))))
        }
        var area = Path()
        area.move(to: CGPoint(x: points[0].x, y: mid))
        area.addLines(points)
        area.addLine(to: CGPoint(x: points[points.count - 1].x, y: mid))
        area.closeSubpath()
        ctx.fill(area, with: .linearGradient(
            Gradient(colors: [s.color.opacity(0.08), s.color.opacity(0.45)]),
            startPoint: CGPoint(x: 0, y: mid), endPoint: CGPoint(x: 0, y: mid + extent)))
        var line = Path()
        line.addLines(points)
        ctx.stroke(line, with: .color(s.color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
    }
}

private struct ScaleLabel: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 3)
            .background(Palette.surface.opacity(0.85))
    }
}

/// Crosshair + tooltip shown while hovering a chart.
private struct HoverReadout: View {
    var x: CGFloat
    var size: CGSize
    var rows: [(String, Color, String)]
    var footer: String

    var body: some View {
        let boxWidth: CGFloat = 132
        let onLeft = x > size.width - boxWidth - 12
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Palette.textSecondary.opacity(0.6))
                .frame(width: 1, height: size.height)
                .offset(x: x - 0.5)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(rows.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        Circle().fill(rows[i].1).frame(width: 7, height: 7)
                        Text(rows[i].0).foregroundStyle(Palette.textSecondary)
                        Spacer(minLength: 4)
                        Text(rows[i].2).foregroundStyle(Palette.textPrimary).monospacedDigit()
                    }
                }
                Text(footer).foregroundStyle(Palette.muted)
            }
            .font(.system(size: 10.5))
            .padding(7)
            .frame(width: boxWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x262624)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.border))
            .offset(x: onLeft ? x - boxWidth - 8 : x + 8, y: 2)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
