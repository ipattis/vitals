import AppKit

/// The app icon is drawn in code so the build needs no image assets.
enum AppIcon {
    static func make(size: CGFloat = 1024) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width / 1024
            // macOS icon grid: 824pt body centred in a 1024pt canvas.
            let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
            let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 24 * s
            shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
            shadow.set()
            NSColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 1).setFill()
            shape.fill()
            NSGraphicsContext.current?.restoreGraphicsState()

            NSGradient(colors: [NSColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1),
                                NSColor(red: 0.06, green: 0.06, blue: 0.065, alpha: 1)])?
                .draw(in: shape, angle: -90)

            // Faint grid lines like the dashboard charts.
            NSGraphicsContext.current?.saveGraphicsState()
            shape.addClip()
            NSColor.white.withAlphaComponent(0.06).setStroke()
            for i in 1...3 {
                let y = body.minY + body.height * CGFloat(i) / 4
                let line = NSBezierPath()
                line.move(to: NSPoint(x: body.minX, y: y))
                line.line(to: NSPoint(x: body.maxX, y: y))
                line.lineWidth = 6 * s
                line.stroke()
            }

            // Pulse trace.
            let points: [(CGFloat, CGFloat)] = [
                (0.00, 0.42), (0.22, 0.42), (0.30, 0.52), (0.36, 0.34), (0.45, 0.80),
                (0.54, 0.22), (0.62, 0.50), (0.70, 0.42), (1.00, 0.42),
            ]
            let trace = NSBezierPath()
            for (i, p) in points.enumerated() {
                let pt = NSPoint(x: body.minX + body.width * p.0, y: body.minY + body.height * p.1)
                if i == 0 { trace.move(to: pt) } else { trace.line(to: pt) }
            }
            trace.lineWidth = 46 * s
            trace.lineJoinStyle = .round
            trace.lineCapStyle = .round

            let fill = trace.copy() as! NSBezierPath
            fill.line(to: NSPoint(x: body.maxX, y: body.minY))
            fill.line(to: NSPoint(x: body.minX, y: body.minY))
            fill.close()
            NSGradient(colors: [NSColor(red: 0.22, green: 0.53, blue: 0.90, alpha: 0.45),
                                NSColor(red: 0.22, green: 0.53, blue: 0.90, alpha: 0.0)])?
                .draw(in: fill, angle: -90)

            NSColor(red: 0.30, green: 0.60, blue: 0.96, alpha: 1).setStroke()
            trace.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()

            NSColor.white.withAlphaComponent(0.10).setStroke()
            shape.lineWidth = 4 * s
            shape.stroke()
            return true
        }
    }

    static func writePNG(to path: String, size: CGFloat = 1024) -> Bool {
        let image = make(size: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
