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

    /// Token counts: "812", "34.1k", "1.25M".
    static func tokens(_ n: Int) -> String {
        let v = Double(max(0, n))
        if v < 1000 { return "\(Int(v))" }
        if v < 1_000_000 { return v < 10_000 ? String(format: "%.1fk", v / 1000) : String(format: "%.0fk", v / 1000) }
        if v < 1_000_000_000 { return v < 10_000_000 ? String(format: "%.2fM", v / 1e6) : String(format: "%.1fM", v / 1e6) }
        return String(format: "%.2fB", v / 1e9)
    }

    /// Durations: "420 ms", "4.2 s", "3m 12s", "2h 5m".
    static func duration(_ s: Double) -> String {
        guard s.isFinite else { return "—" }
        if s < 1 { return "\(Int((s * 1000).rounded())) ms" }
        if s < 60 { return String(format: s < 10 ? "%.1f s" : "%.0f s", s) }
        let t = Int(s)
        if t < 3600 { return "\(t / 60)m \(t % 60)s" }
        return "\(t / 3600)h \((t % 3600) / 60)m"
    }

    /// Time since a date: "now", "45s", "12m", "3h 4m".
    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let s = max(0, now.timeIntervalSince(date))
        if s < 5 { return "now" }
        if s < 60 { return "\(Int(s))s" }
        return uptime(s)
    }

    static func clock(_ date: Date) -> String { clockFormat.string(from: date) }

    private static let clockFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func usd(_ v: Double) -> String { v < 10 ? String(format: "$%.2f", v) : String(format: "$%.0f", v) }
}
