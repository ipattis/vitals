import Foundation

enum Fmt {
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        return "\(Int((max(0, fraction) * 100).rounded()))%"
    }

    /// Memory-style sizes (binary, matching Activity Monitor): "12.4 GB".
    static func memory(_ bytes: UInt64) -> String {
        scaled(Double(bytes), base: 1024, units: ["B", "KB", "MB", "GB", "TB"])
    }

    /// Disk/network sizes (decimal, matching Finder): "512 GB".
    static func storage(_ bytes: UInt64) -> String {
        scaled(Double(bytes), base: 1000, units: ["B", "KB", "MB", "GB", "TB", "PB"])
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        scaled(bytesPerSecond, base: 1000, units: ["B/s", "KB/s", "MB/s", "GB/s"])
    }

    /// Short rate for the menu bar: "1.2M", "340K".
    static func compactRate(_ bytesPerSecond: Double) -> String {
        let units = ["B", "K", "M", "G"]
        var v = max(0, bytesPerSecond), i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        let s = (i == 0 || v >= 10) ? String(format: "%.0f", v) : String(format: "%.1f", v)
        return s + units[i]
    }

    private static func scaled(_ value: Double, base: Double, units: [String]) -> String {
        var v = max(0, value), i = 0
        while v >= base, i < units.count - 1 { v /= base; i += 1 }
        let s: String
        if i == 0 || v >= 100 { s = String(format: "%.0f", v) }
        else if v >= 10 { s = String(format: "%.1f", v) }
        else { s = String(format: "%.2f", v) }
        return "\(s) \(units[i])"
    }

    static func temperature(_ c: Double?) -> String {
        guard let c else { return "—" }
        return String(format: "%.0f°C", c)
    }

    static func watts(_ w: Double?) -> String {
        guard let w else { return "—" }
        return abs(w) >= 10 ? String(format: "%.0f W", w) : String(format: "%.1f W", w)
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let d = total / 86_400, h = (total % 86_400) / 3600, m = (total % 3600) / 60
        if d > 0 { return "\(d)d \(h)h \(m)m" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func minutes(_ m: Int) -> String {
        m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    static func secondsAgo(_ s: Double) -> String {
        s < 0.5 ? "now" : (s < 60 ? "\(Int(s.rounded()))s ago" : "\(Int(s / 60))m \(Int(s) % 60)s ago")
    }
}
