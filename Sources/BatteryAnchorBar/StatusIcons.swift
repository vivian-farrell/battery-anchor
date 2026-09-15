import AppKit

/// Menu bar icons, drawn as template images so macOS tints them for light and dark menu bars.
enum StatusIcons {
    static let size = NSSize(width: 18, height: 18)

    /// Limit on: a bold anchor.
    static let anchor = make("Battery Anchor: holding charge") { ctx in
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Ring
        ctx.setLineWidth(1.8)
        ctx.strokeEllipse(in: CGRect(x: 9 - 1.9, y: 3.7 - 1.9, width: 3.8, height: 3.8))

        // Stock, shank and arms
        ctx.setLineWidth(2.1)
        ctx.move(to: CGPoint(x: 5.2, y: 7.4))
        ctx.addLine(to: CGPoint(x: 12.8, y: 7.4))
        ctx.move(to: CGPoint(x: 9, y: 5.7))
        ctx.addLine(to: CGPoint(x: 9, y: 15.2))

        let center = CGPoint(x: 9, y: 10.3)
        let radius: CGFloat = 5
        let start: CGFloat = 20 * .pi / 180
        let end: CGFloat = 160 * .pi / 180
        for step in 0...24 {
            let angle = start + (end - start) * CGFloat(step) / 24
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if step == 0 { ctx.move(to: point) } else { ctx.addLine(to: point) }
        }
        ctx.strokePath()

        // Flukes: arrowheads continuing each arm tip upward and outward.
        for (angle, direction) in [(end, CGFloat(1)), (start, CGFloat(-1))] {
            let tip = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            let dx = -sin(angle) * direction
            let dy = cos(angle) * direction
            let base = CGPoint(x: tip.x - dx * 0.4, y: tip.y - dy * 0.4)
            ctx.move(to: CGPoint(x: tip.x + dx * 3.1, y: tip.y + dy * 3.1))
            ctx.addLine(to: CGPoint(x: base.x - dy * 1.8, y: base.y + dx * 1.8))
            ctx.addLine(to: CGPoint(x: base.x + dy * 1.8, y: base.y - dx * 1.8))
            ctx.closePath()
        }
        ctx.fillPath()
    }

    /// Limit off: a battery with a lightning bolt.
    static let batteryBolt = make("Battery Anchor: charging normally") { ctx in
        ctx.setLineWidth(1.3)
        let body = CGRect(x: 1.25, y: 5.25, width: 13.5, height: 7.5)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 2.2, cornerHeight: 2.2, transform: nil))
        ctx.strokePath()

        // Terminal
        ctx.addPath(CGPath(roundedRect: CGRect(x: 15.5, y: 7.4, width: 1.6, height: 3.2), cornerWidth: 0.7, cornerHeight: 0.7, transform: nil))
        ctx.fillPath()

        // Bolt
        ctx.move(to: CGPoint(x: 9.0, y: 6.1))
        ctx.addLine(to: CGPoint(x: 5.4, y: 9.5))
        ctx.addLine(to: CGPoint(x: 7.7, y: 9.5))
        ctx.addLine(to: CGPoint(x: 7.0, y: 11.9))
        ctx.addLine(to: CGPoint(x: 10.6, y: 8.5))
        ctx.addLine(to: CGPoint(x: 8.3, y: 8.5))
        ctx.closePath()
        ctx.fillPath()
    }

    /// The service isn't running, so neither state is being enforced.
    static let warning: NSImage = {
        let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Battery Anchor: service not running")
            ?? NSImage(size: size)
        image.isTemplate = true
        return image
    }()

    /// Draws in a flipped (top-left origin) 18×18 point space; macOS tints the result.
    private static func make(_ description: String, draw: @escaping (CGContext) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)
            draw(ctx)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
