import AppKit

/// Draws the menu bar item as compact two-line stacks (small label over value), the way
/// iStat Menus does, so several readings fit in little horizontal space. The result is a
/// template image, so macOS tints it correctly for light, dark and tinted menu bars.
enum MenuBarRenderer {
    private struct Stack {
        var top: String
        var bottom: String
        var topSample: String      // widest expected text, so the item never jitters
        var bottomSample: String
        var alignRight = false
    }

    private static let labelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    private static let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)

    static func image(for s: Snapshot, items: Set<MenuBarItem>) -> NSImage? {
        var stacks: [Stack] = []
        for item in MenuBarItem.allCases where items.contains(item) {
            switch item {
            case .agents:
                let working = s.agents.filter(\.isWorking).count
                stacks.append(Stack(top: "AGENTS", bottom: "\(working)", topSample: "AGENTS", bottomSample: "99"))
            case .cpu:
                stacks.append(Stack(top: "CPU", bottom: Fmt.percent(s.cpu.total), topSample: "CPU", bottomSample: "100%"))
            case .gpu:
                stacks.append(Stack(top: "GPU", bottom: Fmt.percent(s.gpu?.device ?? 0), topSample: "GPU", bottomSample: "100%"))
            case .memory:
                stacks.append(Stack(top: "MEM", bottom: Fmt.percent(s.memory.usedFraction), topSample: "MEM", bottomSample: "100%"))
            case .network:
                stacks.append(Stack(top: "↑ " + Fmt.compactRate(s.network.upRate), bottom: "↓ " + Fmt.compactRate(s.network.downRate),
                                    topSample: "↑ 999K", bottomSample: "↓ 999K", alignRight: true))
            case .disk:
                stacks.append(Stack(top: "R " + Fmt.compactRate(s.disk.readRate), bottom: "W " + Fmt.compactRate(s.disk.writeRate),
                                    topSample: "R 999K", bottomSample: "W 999K", alignRight: true))
            case .temperature:
                if let t = s.sensors.cpu {
                    stacks.append(Stack(top: "TEMP", bottom: String(format: "%.0f°", t), topSample: "TEMP", bottomSample: "100°"))
                }
            case .power:
                if let w = s.power.systemPower {
                    stacks.append(Stack(top: "POWER", bottom: String(format: "%.0fW", w), topSample: "POWER", bottomSample: "100W"))
                }
            }
        }
        guard !stacks.isEmpty else { return nil }

        let height: CGFloat = 22
        let gap: CGFloat = 7
        func attrs(_ font: NSFont) -> [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.black] }
        func fonts(_ st: Stack) -> (NSFont, NSFont) { st.alignRight ? (rateFont, rateFont) : (labelFont, valueFont) }
        let widths = stacks.map { st -> CGFloat in
            let (tf, bf) = fonts(st)
            return ceil(max((st.topSample as NSString).size(withAttributes: attrs(tf)).width,
                            (st.bottomSample as NSString).size(withAttributes: attrs(bf)).width))
        }
        let total = widths.reduce(0, +) + gap * CGFloat(stacks.count - 1)

        let image = NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (st, w) in zip(stacks, widths) {
                let (tf, bf) = fonts(st)
                let top = NSAttributedString(string: st.top, attributes: attrs(tf))
                let bottom = NSAttributedString(string: st.bottom, attributes: attrs(bf))
                func originX(_ str: NSAttributedString) -> CGFloat {
                    st.alignRight ? x + w - str.size().width : x + (w - str.size().width) / 2
                }
                let bottomY: CGFloat = st.alignRight ? 1 : 0
                bottom.draw(at: NSPoint(x: originX(bottom), y: bottomY))
                top.draw(at: NSPoint(x: originX(top), y: st.alignRight ? 11 : 12))
                x += w + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
