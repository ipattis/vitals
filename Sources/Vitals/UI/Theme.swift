import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }
}

/// Dark-surface palette. Series colours are the validated dark-mode categorical steps;
/// paired series (user/system, down/up, read/write) always use slots 1+2 (blue/orange),
/// which pass the colour-blind separation check. Status colours are reserved for state.
enum Palette {
    static let page = Color(hex: 0x0d0d0d)
    static let surface = Color(hex: 0x1a1a19)
    static let textPrimary = Color(hex: 0xf0efec)
    static let textSecondary = Color(hex: 0xc3c2b7)
    static let muted = Color(hex: 0x898781)
    static let grid = Color(hex: 0x2c2c2a)
    static let baseline = Color(hex: 0x383835)
    static let border = Color.white.opacity(0.10)

    static let blue = Color(hex: 0x3987e5)
    static let orange = Color(hex: 0xd95926)
    static let aqua = Color(hex: 0x199e70)
    static let yellow = Color(hex: 0xc98500)
    static let violet = Color(hex: 0x9085e9)
    static let red = Color(hex: 0xe66767)

    enum Status {
        static let good = Color(hex: 0x0ca30c)
        static let warning = Color(hex: 0xfab219)
        static let serious = Color(hex: 0xec835a)
        static let critical = Color(hex: 0xd03b3b)
    }
}

enum StatusLevel {
    case good, warning, serious, critical

    var color: Color {
        switch self {
        case .good: Palette.Status.good
        case .warning: Palette.Status.warning
        case .serious: Palette.Status.serious
        case .critical: Palette.Status.critical
        }
    }

    var symbol: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .serious: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }
}
