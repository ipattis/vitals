import AppKit
import SwiftUI

struct Card<Content: View, Accessory: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 18)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.border))
    }
}

/// Big number shown in a card header.
struct HeroValue: View {
    var value: String
    var caption: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
                .contentTransition(.numericText())
            if let caption {
                Text(caption).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
    }
}

struct StatRow: View {
    var label: String
    var value: String
    var dot: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(label).foregroundStyle(Palette.textSecondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(Palette.textPrimary).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 12))
    }
}

struct LegendItem: View {
    var color: Color
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(Palette.textSecondary)
            Text(value).foregroundStyle(Palette.textPrimary).monospacedDigit()
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1)
            .foregroundStyle(Palette.muted)
            .padding(.top, 2)
    }
}

struct MeterBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.grid)
                Capsule().fill(color)
                    .frame(width: max(fraction > 0 ? height : 0, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: height)
    }
}

/// Horizontal bar of adjacent segments separated by 2px surface gaps.
struct SegmentedBar: View {
    struct Segment { var value: Double; var color: Color }
    var segments: [Segment]
    var total: Double
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let visible = segments.filter { $0.value > 0 }
            let usable = geo.size.width - gap * CGFloat(max(0, visible.count - 1))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Palette.grid)
                HStack(spacing: gap) {
                    ForEach(visible.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(visible[i].color)
                            .frame(width: max(1, usable * CGFloat(visible[i].value / max(total, 1))))
                    }
                }
            }
        }
        .frame(height: height)
    }
}

/// One vertical bar per logical core, grouped by efficiency/performance cluster.
struct CoreBars: View {
    var cores: [Double]
    var kinds: [CoreKind]
    private let barGap: CGFloat = 2
    private let groupGap: CGFloat = 10
    private let barHeight: CGFloat = 40

    var body: some View {
        let groups = grouped()
        GeometryReader { geo in
            let gaps = groupGap * CGFloat(max(0, groups.count - 1)) + barGap * CGFloat(max(0, cores.count - groups.count))
            let barWidth = max(2, (geo.size.width - gaps) / CGFloat(max(1, cores.count)))
            HStack(alignment: .top, spacing: groupGap) {
                ForEach(groups.indices, id: \.self) { g in
                    let group = groups[g]
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .bottom, spacing: barGap) {
                            ForEach(group.indices, id: \.self) { j in
                                let (index, value) = group.items[j]
                                ZStack(alignment: .bottom) {
                                    UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2).fill(Palette.grid)
                                    UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                                        .fill(Palette.blue)
                                        .frame(height: max(1, barHeight * CGFloat(min(1, value))))
                                }
                                .frame(width: barWidth, height: barHeight)
                                .help("Core \(index + 1) (\(group.short)): \(Fmt.percent(value))")
                            }
                        }
                        Text("\(group.title) · \(Fmt.percent(group.average))")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
        .frame(height: barHeight + 18)
    }

    private struct Group {
        var title: String
        var short: String
        var items: [(Int, Double)]
        var indices: Range<Int> { items.indices }
        var average: Double { items.isEmpty ? 0 : items.map(\.1).reduce(0, +) / Double(items.count) }
    }

    private func grouped() -> [Group] {
        let pairs = Array(cores.enumerated())
        let e = pairs.filter { kinds.indices.contains($0.offset) && kinds[$0.offset] == .efficiency }
        let p = pairs.filter { kinds.indices.contains($0.offset) && kinds[$0.offset] == .performance }
        if e.isEmpty || p.isEmpty {
            return [Group(title: "\(cores.count) cores", short: "core", items: pairs.map { ($0.offset, $0.element) })]
        }
        return [Group(title: "E-cores", short: "E", items: e.map { ($0.offset, $0.element) }),
                Group(title: "P-cores", short: "P", items: p.map { ($0.offset, $0.element) })]
    }
}

struct StatusBadge: View {
    var level: StatusLevel
    var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: level.symbol).foregroundStyle(level.color)
            Text(text).foregroundStyle(Palette.textPrimary)
        }
        .font(.system(size: 12))
    }
}

struct ProcessList: View {
    var items: [ProcessUsage]
    var value: (ProcessUsage) -> String

    var body: some View {
        VStack(spacing: 5) {
            ForEach(items) { item in
                HStack(spacing: 7) {
                    ProcessIconView(pid: item.pid)
                    Text(item.name.trimmingCharacters(in: .whitespaces))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(value(item)).foregroundStyle(Palette.textPrimary).monospacedDigit()
                }
                .font(.system(size: 12))
            }
        }
    }
}

private struct ProcessIconView: View {
    var pid: pid_t
    var body: some View {
        if let image = ProcessIcons.icon(for: pid) {
            Image(nsImage: image).resizable().frame(width: 15, height: 15)
        } else {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)
                .frame(width: 15, height: 15)
        }
    }
}

/// Resolves an icon for a pid: the running app's icon, or the enclosing .app bundle for helpers.
enum ProcessIcons {
    private static var cache: [pid_t: NSImage?] = [:]

    static func icon(for pid: pid_t) -> NSImage? {
        if let cached = cache[pid] { return cached }
        var image: NSImage?
        if let app = NSRunningApplication(processIdentifier: pid), app.bundleURL != nil {
            image = app.icon
        } else {
            var buffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                let path = String(cString: buffer)
                if let range = path.range(of: ".app/") {
                    image = NSWorkspace.shared.icon(forFile: String(path[..<range.lowerBound]) + ".app")
                }
            }
        }
        if cache.count > 500 { cache.removeAll() }
        cache[pid] = image
        return image
    }
}

/// Masonry layout: places each card in the currently shortest column.
struct MasonryLayout: Layout {
    var minColumnWidth: CGFloat = 340
    var spacing: CGFloat = 12

    private func columns(for width: CGFloat) -> (count: Int, width: CGFloat) {
        let width = max(minColumnWidth, width)
        let count = max(1, min(8, Int((width + spacing) / (minColumnWidth + spacing))))
        return (count, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    /// SwiftUI probes layouts with nil/zero/infinite widths; size those as a single column.
    private func usableWidth(_ proposed: CGFloat?) -> CGFloat {
        guard let w = proposed, w.isFinite, w > 0 else { return minColumnWidth }
        return w
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let (count, colWidth) = columns(for: width)
        var heights = [CGFloat](repeating: 0, count: count)
        return subviews.map { view in
            let col = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let size = view.sizeThatFits(ProposedViewSize(width: colWidth, height: nil))
            let frame = CGRect(x: CGFloat(col) * (colWidth + spacing), y: heights[col], width: colWidth, height: size.height)
            heights[col] += size.height + spacing
            return frame
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = usableWidth(proposal.width)
        let f = frames(width: width, subviews: subviews)
        return CGSize(width: width, height: max(0, (f.map(\.maxY).max() ?? 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: usableWidth(bounds.width), subviews: subviews)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}
