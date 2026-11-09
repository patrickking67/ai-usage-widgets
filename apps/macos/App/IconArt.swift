import AppKit

/// The app icon: two rings on a dark tile. The same drawing makes the static
/// icon (scripts/make-icon.sh, with fixed fills) and the live Dock icon, whose
/// rings fill to each lane's hottest window.
enum IconArt {
    struct Ring {
        var fraction: Double
        var from: NSColor   // gradient along the arc, start to end
        var to: NSColor
    }

    static let clay = (NSColor(red: 0.96, green: 0.66, blue: 0.50, alpha: 1), NSColor(red: 0.85, green: 0.43, blue: 0.30, alpha: 1))
    static let blue = (NSColor(red: 0.58, green: 0.74, blue: 1.00, alpha: 1), NSColor(red: 0.30, green: 0.50, blue: 0.98, alpha: 1))
    static let violet = (NSColor(red: 0.74, green: 0.60, blue: 1.00, alpha: 1), NSColor(red: 0.52, green: 0.33, blue: 0.95, alpha: 1))

    /// The static icon's fills: enough of each ring to read as a meter.
    static let showcase = [Ring(fraction: 0.78, from: clay.0, to: clay.1), Ring(fraction: 0.46, from: blue.0, to: blue.1)]

    static func cgImage(px: Int, rings: [Ring]) -> CGImage? {
        let s = CGFloat(px)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // macOS icon grid: an 824/1024 tile, centred, with a continuous-corner radius.
        let inset = s * 100 / 1024
        let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let radius = tile.width * 0.2245
        let shape = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                      color: CGColor(gray: 0, alpha: 0.4))
        ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0.05, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bg = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.20, green: 0.21, blue: 0.26, alpha: 1),
            CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(bg, startCenter: CGPoint(x: tile.minX + tile.width * 0.3, y: tile.maxY - tile.height * 0.2),
                               startRadius: 0, endCenter: CGPoint(x: tile.midX, y: tile.midY),
                               endRadius: tile.width * 0.85, options: [.drawsAfterEndLocation])

        let c = CGPoint(x: tile.midX, y: tile.midY)
        let line = tile.width * 0.088
        let radii = [tile.width * 0.315, tile.width * 0.315 - line * 1.32, tile.width * 0.315 - line * 2.64]
        for (i, ring) in rings.prefix(3).enumerated() {
            let r = radii[i]
            ctx.setLineWidth(line)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
            ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()
            let f = CGFloat(min(max(ring.fraction, 0), 1))
            guard f > 0.004 else { continue }
            // A gradient along the arc, drawn as short segments; then a soft
            // glow in the end colour under the round head.
            let steps = max(Int(f * 90), 2)
            ctx.setLineCap(.butt)
            for k in 0..<steps {
                let t0 = CGFloat(k) / CGFloat(steps), t1 = CGFloat(k + 1) / CGFloat(steps)
                ctx.setStrokeColor(blend(ring.from, ring.to, t0).cgColor)
                // Each segment runs into the next, which paints over it: no seams.
                let overlap: CGFloat = k == steps - 1 ? 0 : 0.03
                ctx.addArc(center: c, radius: r, startAngle: .pi / 2 - .pi * 2 * f * t0,
                           endAngle: .pi / 2 - .pi * 2 * f * t1 - overlap, clockwise: true)
                ctx.strokePath()
            }
            ctx.setLineCap(.round)
            ctx.setStrokeColor(ring.from.cgColor)
            ctx.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - 0.001, clockwise: true)
            ctx.strokePath()
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: line * 0.9, color: ring.to.withAlphaComponent(0.8).cgColor)
            ctx.setStrokeColor(ring.to.cgColor)
            let end = .pi / 2 - .pi * 2 * f
            ctx.addArc(center: c, radius: r, startAngle: end + 0.001, endAngle: end, clockwise: true)
            ctx.strokePath()
            ctx.restoreGState()
        }
        // Hairline edge, as on the system icons.
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.09))
        ctx.setLineWidth(max(1, s / 400))
        ctx.addPath(shape); ctx.strokePath()
        ctx.restoreGState()
        return ctx.makeImage()
    }

    private static func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        a.usingColorSpace(.sRGB)!.blended(withFraction: t, of: b.usingColorSpace(.sRGB)!) ?? a
    }
}
