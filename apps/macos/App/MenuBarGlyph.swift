import AppKit

/// The menu bar logo: one ring per lane (two at most, outer first), each
/// filled to that lane's hottest window, and a dot in the middle while Keep
/// Awake is holding. A template image, so it takes the menu bar's own colour.
enum MenuBarGlyph {
    static func image(fractions: [Double], awake: Bool) -> NSImage {
        let lanes = Array(fractions.prefix(2))
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            // One lane gets one bolder ring; none or two get the two-ring mark.
            let rings: [(CGFloat, CGFloat)] = lanes.count == 1 ? [(6.6, 2.4)] : [(7.4, 2.0), (4.2, 2.0)]
            for (i, (r, line)) in rings.enumerated() {
                let track = NSBezierPath()
                track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
                track.lineWidth = line
                NSColor.black.withAlphaComponent(0.3).setStroke()
                track.stroke()
                guard i < lanes.count, lanes[i] > 0.005 else { continue }
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: r, startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(min(lanes[i], 1)), clockwise: true)
                arc.lineWidth = line
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            if awake {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: CGRect(x: c.x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
