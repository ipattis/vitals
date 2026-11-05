import AppKit
import SwiftUI

let arguments = CommandLine.arguments

// `Vitals --export-icon <file.png>` renders the app icon (used by build.sh).
if let i = arguments.firstIndex(of: "--export-icon"), i + 1 < arguments.count {
    exit(AppIcon.writePNG(to: arguments[i + 1]) ? 0 : 1)
}

// `Vitals --dump` prints one set of readings to the terminal and exits.
if arguments.contains("--dump") {
    let monitor = SystemMonitor()
    monitor.start(interval: 1)
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
        let s = monitor.snapshot
        print("CPU      \(Fmt.percent(s.cpu.total)) (user \(Fmt.percent(s.cpu.user)), system \(Fmt.percent(s.cpu.system))), \(s.cpu.cores.count) cores")
        if let g = s.gpu { print("GPU      \(Fmt.percent(g.device)) \(g.name), \(Fmt.memory(g.memoryInUse)) in use") }
        print("Memory   \(Fmt.memory(s.memory.used)) of \(Fmt.memory(s.memory.total)), pressure \(Fmt.percent(s.memory.pressure))")
        print("Network  ↓ \(Fmt.rate(s.network.downRate))  ↑ \(Fmt.rate(s.network.upRate))  \(s.network.primaryName ?? "offline") \(s.network.primaryAddress ?? "")")
        print("Disk     read \(Fmt.rate(s.disk.readRate))  write \(Fmt.rate(s.disk.writeRate))")
        for v in s.disk.volumes { print("         \(v.name): \(Fmt.storage(v.available)) free of \(Fmt.storage(v.total))") }
        print("Sensors  CPU \(Fmt.temperature(s.sensors.cpu)), SSD \(Fmt.temperature(s.sensors.ssd)), fans \(s.sensors.fans.map { "\(Int($0.rpm)) rpm" })")
        print("Power    system \(Fmt.watts(s.power.systemPower))" + (s.power.hasBattery ? ", battery \(Fmt.percent(s.power.level))" : ""))
        for a in s.agents {
            var line = "Agent    [\(a.statusText)] \(a.title) · \(a.source)"
            if let p = a.project { line += " · \(p)" }
            line += " · CPU \(Fmt.percent(a.cpu)) · \(Fmt.memory(a.memory)) · GPU \(Fmt.percent(a.gpu)) · \(a.processCount) procs"
            if let b = a.busiest { line += " · busiest: \(b.command) \(Fmt.percent(b.cpu))" }
            if !a.subagents.isEmpty { line += " · subagents: " + a.subagents.map(\.description).joined(separator: ", ") }
            print(line)
        }
        exit(0)
    }
    dispatchMain()
}

// `Vitals --snapshot <file.png> [width height]` renders the live dashboard to an image.
if let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count {
    MainActor.assumeIsolated {
        let path = arguments[i + 1]
        let w = arguments.count > i + 3 ? Double(arguments[i + 2]) ?? 1120 : 1120
        let h = arguments.count > i + 3 ? Double(arguments[i + 3]) ?? 820 : 820
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let monitor = SystemMonitor()
        let settings = AppSettings()
        monitor.start(interval: 0.5)
        let view = NSHostingView(rootView: DashboardView(monitor: monitor, settings: settings))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: 0, width: w, height: h),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            // Also render the menu bar item on light and dark bars, at 4x for inspection.
            let items = Set(MenuBarItem.allCases)
            if let bar = MenuBarRenderer.image(for: monitor.snapshot, items: settings.menuBar),
               let all = MenuBarRenderer.image(for: monitor.snapshot, items: items) {
                let scale: CGFloat = 4, pad: CGFloat = 8
                let width = max(bar.size.width, all.size.width) + pad * 2
                let size = NSSize(width: width * scale, height: (22 * 4 + pad * 5) * scale)
                let out = NSImage(size: size, flipped: false) { _ in
                    var y = pad
                    for (img, dark) in [(bar, true), (bar, false), (all, true), (all, false)] {
                        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                        NSRect(x: 0, y: y * scale, width: width * scale, height: 22 * scale).fill()
                        let tinted = NSImage(size: img.size, flipped: false) { r in
                            img.draw(in: r)
                            (dark ? NSColor.white : NSColor.black).set()
                            r.fill(using: .sourceAtop)
                            return true
                        }
                        tinted.draw(in: NSRect(x: pad * scale, y: y * scale, width: img.size.width * scale, height: 22 * scale))
                        y += 22 + pad
                    }
                    return true
                }
                if let tiff = out.tiffRepresentation, let r = NSBitmapImageRep(data: tiff) {
                    try? r.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-menubar.png")))
                }
            }
            exit(0)
        }
        app.run()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
