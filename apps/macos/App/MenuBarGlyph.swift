import AppKit

/// The menu bar logo: one ring per lane (two at most, outer first), each
/// filled to that lane's hottest window. While Keep Awake is on, a small cup
/// sits in the lower right corner, cut out of the rings: outlined while it is
/// waiting for an agent, filled while it is holding the Mac awake. A template
/// image, so it takes the menu bar's own colour.
enum MenuBarGlyph {
    enum Awake { case off, armed, holding }

    static func image(fractions: [Double], awake: Awake) -> NSImage {
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
            guard awake != .off, let ctx = NSGraphicsContext.current else { return true }
            let badge = CGRect(x: rect.maxX - 9, y: rect.minY, width: 9, height: 9)
            // Knock a hole in the rings so the cup reads at 18 points.
            ctx.compositingOperation = .clear
            NSBezierPath(ovalIn: badge.insetBy(dx: -1.2, dy: -1.2)).fill()
            ctx.compositingOperation = .sourceOver
            let name = awake == .holding ? "cup.and.saucer.fill" : "cup.and.saucer"
            if let cup = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 7.5, weight: .bold)) {
                let s = cup.size
                cup.draw(in: CGRect(x: badge.midX - s.width / 2, y: badge.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
