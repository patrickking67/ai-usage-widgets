import SwiftUI
import WidgetKit

// MARK: - Rings
//
// The glanceable form: one ring per lane, filled to its hottest window.
// Ring colour is the vendor's, so the rings tell lanes apart; the number
// beside each one carries pace colour, as the bars do.

/// Lanes worth a ring: the ones with a window that can run out.
func ringLanes(_ board: UsageBoard?, limit: Int) -> [ProviderUsage] {
    Array((board?.providers ?? []).filter { !$0.meters.isEmpty }.prefix(limit))
}

/// Small widget: nested rings, the hottest number in the middle, a legend below.
struct RingStack: View {
    var providers: [ProviderUsage]
    var now: Date

    var body: some View {
        let hot = providers.compactMap { p in p.hottest(at: now).map { (p, $0) } }
            .max { $0.1.fraction(at: now) < $1.1.fraction(at: now) }
        VStack(spacing: 8) {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let line = max(side * 0.105, 7)
                ZStack {
                    ForEach(Array(providers.enumerated()), id: \.element.id) { i, p in
                        let m = p.hottest(at: now)
                        UsageRing(fraction: m?.fraction(at: now) ?? 0, tint: Palette.vendor(p.vendor), lineWidth: line)
                            .padding(CGFloat(i) * (line + 2.5))
                            .opacity(p.isStale(at: now) ? 0.5 : 1)
                    }
                    if let (p, m) = hot {
                        VStack(spacing: 0) {
                            Text("\(Int((m.fraction(at: now) * 100).rounded()))%")
                                .font(.system(size: side * 0.15, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText(value: m.fraction(at: now)))
                            if m.limitDate(at: now) != nil, !p.isStale(at: now) {
                                Image(systemName: "flame.fill").font(.system(size: side * 0.08))
                                    .foregroundStyle(m.tint(at: now)).widgetAccentable()
                            }
                        }
                    }
                }
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 8) {
                ForEach(providers) { p in RingLegend(provider: p, now: now) }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Icon and hottest percent, the legend under the stacked rings.
private struct RingLegend: View {
    var provider: ProviderUsage
    var now: Date

    var body: some View {
        let m = provider.hottest(at: now)
        HStack(spacing: 3) {
            VendorIcon(vendor: provider.vendor, size: 11)
            Text(m.map { "\(Int(($0.fraction(at: now) * 100).rounded()))%" } ?? "—")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(provider.isStale(at: now) ? .secondary : .primary)
        }
        .lineLimit(1)
    }
}

/// Medium widget and dashboard header: a ring per lane, side by side,
/// each with its number inside and its reset underneath.
struct RingRow: View {
    var providers: [ProviderUsage]
    var now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(providers) { p in
                RingCell(provider: p, now: now).frame(maxWidth: .infinity)
            }
        }
    }
}

private struct RingCell: View {
    var provider: ProviderUsage
    var now: Date

    var body: some View {
        let m = provider.hottest(at: now)
        let f = m?.fraction(at: now) ?? 0
        let stale = provider.isStale(at: now)
        VStack(spacing: 6) {
            ZStack {
                UsageRing(fraction: f, tint: Palette.vendor(provider.vendor), lineWidth: 8)
                    .opacity(stale ? 0.5 : 1)
                VStack(spacing: 1) {
                    VendorIcon(vendor: provider.vendor, size: 13)
                    Text(m == nil ? "—" : "\(Int((f * 100).rounded()))%")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(stale ? AnyShapeStyle(.secondary) : AnyShapeStyle(m?.tint(at: now) ?? .primary))
                        .contentTransition(.numericText(value: f))
                }
            }
            .frame(width: 72, height: 72)
            VStack(spacing: 1) {
                Text(provider.vendor.shortName)
                    .font(.system(size: 10, weight: .semibold)).lineLimit(1)
                Group {
                    if stale, let u = provider.updated {
                        Text(u.ago(from: now))
                    } else if let m {
                        ResetLabel(meter: m, now: now)
                    }
                }
                .font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
    }
}

extension Vendor {
    /// Fits under a 72pt ring.
    var shortName: String {
        switch self {
        case .claude:  "Claude"
        case .copilot: "Copilot"
        default:       displayName
        }
    }
}
