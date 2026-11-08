import SwiftUI
import WidgetKit

// MARK: - Rendering mode
//
// A desktop widget is drawn in full colour only while the desktop has focus.
// With any app in front, macOS switches it to `.vibrant`: colour is discarded
// and every pixel becomes a brightness over the wallpaper. Full-colour app
// icons turn into grey blobs there, and red/amber/cyan bars become the same
// grey. So every shared view asks which mode it is in and draws for it.

private struct ForceVibrantKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Draw as if vibrant. Lets `--render` preview the desktop look offscreen.
    var forceVibrant: Bool {
        get { self[ForceVibrantKey.self] }
        set { self[ForceVibrantKey.self] = newValue }
    }
}

/// True when colour will not survive: vibrant (desktop, unfocused) or
/// accented (tinted) rendering.
struct IsVibrant: DynamicProperty {
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.forceVibrant) private var forced
    var wrappedValue: Bool { forced || mode != .fullColor }
}

// MARK: - Pieces

/// Thin capsule meter, after the usage bars in the Claude app.
///
/// `pace` draws a notch where the bar would sit with perfectly even use across
/// the window: fill past the notch is running hot, short of it is headroom.
struct UsageBar: View {
    var fraction: Double
    var tint: Color
    var height: CGFloat = 5
    var pace: Double? = nil
    private var vibrant = IsVibrant()

    init(fraction: Double, tint: Color, height: CGFloat = 5, pace: Double? = nil) {
        self.fraction = fraction; self.tint = tint; self.height = height; self.pace = pace
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // A 10% track vanishes once colour is stripped; brightness
                // is the only contrast left, so the track steps up.
                Capsule().fill(.primary.opacity(vibrant.wrappedValue ? 0.22 : 0.10))
                fill
                    .frame(width: max(geo.size.width * fraction, fraction > 0 ? height : 0))
                if let pace, pace > 0.02, pace < 0.98 {
                    Capsule()
                        .fill(.primary.opacity(vibrant.wrappedValue ? 0.9 : 0.55))
                        .frame(width: 1.5, height: height + 4)
                        .offset(x: geo.size.width * pace - 0.75)
                }
            }
        }
        .frame(height: height)
    }

    @ViewBuilder private var fill: some View {
        if vibrant.wrappedValue {
            Capsule().fill(.primary).widgetAccentable()
        } else {
            Capsule().fill(tint.gradient)
        }
    }
}

/// Activity-style ring. Like `UsageBar`, it drops colour for brightness
/// when the widget is drawn vibrant.
struct UsageRing: View {
    var fraction: Double
    var tint: Color
    var lineWidth: CGFloat = 7
    private var vibrant = IsVibrant()

    init(fraction: Double, tint: Color, lineWidth: CGFloat = 7) {
        self.fraction = fraction; self.tint = tint; self.lineWidth = lineWidth
    }

    var body: some View {
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        // A sliver keeps the round cap visible at 0%, so an empty lane still reads as a ring.
        let arc = Circle().trim(from: 0, to: min(max(fraction, 0.002), 1)).rotation(.degrees(-90))
        ZStack {
            Circle().stroke(.primary.opacity(vibrant.wrappedValue ? 0.22 : 0.12), lineWidth: lineWidth)
            if vibrant.wrappedValue {
                arc.stroke(.primary, style: style).widgetAccentable()
            } else {
                arc.stroke(tint.gradient, style: style)
            }
        }
        .padding(lineWidth / 2)
    }
}

/// The full-colour app icon when colour survives; otherwise a template glyph
/// cut from that icon, which the system draws bright over any wallpaper.
struct VendorIcon: View {
    var vendor: Vendor
    var size: CGFloat = 18
    private var vibrant = IsVibrant()

    init(vendor: Vendor, size: CGFloat = 18) { self.vendor = vendor; self.size = size }

    /// Decorative: the vendor's name is always beside it or in the parent's label.
    var body: some View {
        icon.accessibilityHidden(true)
    }

    @ViewBuilder private var icon: some View {
        if vibrant.wrappedValue {
            Group {
                if let glyph = vendor.glyph {
                    Image(glyph).renderingMode(.template).resizable().interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: vendor.symbol).resizable().aspectRatio(contentMode: .fit)
                        .fontWeight(.semibold)
                }
            }
            .frame(width: size * 0.8, height: size * 0.8)
            .frame(width: size, height: size)
            .foregroundStyle(.primary)
            .widgetAccentable()
        } else if let icon = vendor.appIcon {
            Image(icon).resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            // No bundled artwork: a tile in the vendor's colour, app-icon shaped.
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(Palette.vendor(vendor).gradient)
                .overlay {
                    Image(systemName: vendor.symbol).resizable().aspectRatio(contentMode: .fit)
                        .fontWeight(.bold).foregroundStyle(.white)
                        .padding(size * 0.24)
                }
                .frame(width: size, height: size)
        }
    }
}

/// Monochrome vendor mark for the menu bar.
struct VendorMark: View {
    var vendor: Vendor
    var body: some View {
        if let mark = vendor.mark { Image(mark) } else { Image(systemName: vendor.symbol) }
    }
}

/// "5 hr, 59 min left", ticking by itself; "Resets Wednesday" past a day.
///
/// `style: .relative` is redrawn by the system every second, so the widget
/// counts down between timeline entries instead of jumping once a minute.
struct ResetLabel: View {
    var meter: Meter
    var now: Date

    var body: some View {
        if let r = meter.resetDate, r > now, r.timeIntervalSince(now) < 86_400 {
            Text("\(r, style: .relative) left")
        } else {
            Text(meter.resetText(at: now))
        }
    }
}

/// "On pace for 64%" — or, when the rate so far would exhaust the window
/// before it resets, "Limit in 1 hr, 40 min", ticking live.
struct PaceNote: View {
    var meter: Meter
    var now: Date

    var body: some View {
        if let hit = meter.limitDate(at: now) {
            HStack(spacing: 3) {
                Image(systemName: "flame.fill").widgetAccentable()
                Text("Limit in \(hit, style: .relative)")
            }
            .foregroundStyle(meter.tint(at: now))
        } else if let p = meter.projectedAtReset(at: now) {
            Text("On pace for \(Int(p.rounded()))%")
        }
    }
}

/// Pay-as-you-go spend beyond the plan, with a bar when there is a cap.
struct ExtraRow: View {
    var extra: ExtraSpend
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "creditcard").font(.system(size: compact ? 8 : 9))
                Text("Extra usage")
                Spacer(minLength: 4)
                Text(extra.text).monospacedDigit().foregroundStyle(.primary)
            }
            .font(.system(size: compact ? 9 : 10, weight: .medium))
            .foregroundStyle(.secondary)
            if let f = extra.fraction {
                UsageBar(fraction: f, tint: f >= 0.9 ? Palette.red : Palette.clay, height: 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Extra usage")
        .accessibilityValue(extra.text)
    }
}

/// Where this week went: one segmented bar, then "Cowork 46 · Claude Code 34".
struct BreakdownRow: View {
    var shares: [Share]
    private var vibrant = IsVibrant()

    init(shares: [Share]) { self.shares = shares }

    private static let tints: [Color] = [Palette.clay, Palette.cyan, Palette.amber,
                                         Color(red: 0.55, green: 0.36, blue: 0.96), .gray]

    var body: some View {
        let total = max(shares.reduce(0) { $0 + $1.percent }, 1)
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(Array(shares.enumerated()), id: \.element.id) { i, s in
                        Rectangle()
                            .fill(vibrant.wrappedValue ? AnyShapeStyle(.primary.opacity(1 - Double(i) * 0.18))
                                                       : AnyShapeStyle(Self.tints[i % Self.tints.count]))
                            .frame(width: max(geo.size.width * s.percent / total - 1.5, 2))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 3)
            Text(shares.map { "\($0.label) \(Int($0.percent.rounded()))%" }.joined(separator: " · "))
                .font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .help("Share of this week's usage by surface")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Share of this week's usage")
        .accessibilityValue(shares.map { "\($0.label) \(Int($0.percent.rounded())) percent" }.joined(separator: ", "))
    }
}

/// "Live" with a dot, or "4d ago" with a clock once the vendor has gone quiet.
struct FreshnessBadge: View {
    var provider: ProviderUsage
    var now: Date
    var compact = false

    var body: some View {
        if let u = provider.updated {
            let stale = provider.isStale(at: now)
            HStack(spacing: 3) {
                if stale {
                    Image(systemName: "clock").font(.system(size: compact ? 7 : 8, weight: .semibold))
                    Text(u.ago(from: now))
                } else {
                    Circle().fill(Palette.cyan).frame(width: 5, height: 5).widgetAccentable()
                    Text(u.ago(from: now) == "Live" ? "Live" : u.ago(from: now))
                }
            }
            .font(.system(size: compact ? 8 : 9, weight: .medium))
            .foregroundStyle(stale ? .secondary : .tertiary)
            .monospacedDigit()
            .help(stale ? "Last reported \(u.ago(from: now)); this number may be out of date." : "")
        }
    }
}

// MARK: - Rows and cards

/// "Current · 37% · 4h 13m Left" with a bar underneath.
struct MeterRow: View {
    var meter: Meter
    var now: Date
    var compact = false
    var stale = false

    var body: some View {
        let f = meter.fraction(at: now)
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(meter.label)
                    .font(.system(size: compact ? 10 : 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                // Colour carries "near the limit" in full colour; the glyph
                // carries it when the widget is drawn without colour.
                if f >= 0.9 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: compact ? 8 : 9))
                        .foregroundStyle(meter.tint(at: now))
                        .widgetAccentable()
                }
                Text("\(Int((f * 100).rounded()))%")
                    .font(.system(size: compact ? 11 : 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(stale ? .secondary : .primary)
                    .contentTransition(.numericText(value: f))
            }
            UsageBar(fraction: f, tint: meter.tint(at: now), height: compact ? 4 : 5,
                     pace: stale ? nil : meter.elapsedFraction(at: now))
                .opacity(stale ? 0.55 : 1)
            if !compact {
                HStack(spacing: 6) {
                    ResetLabel(meter: meter, now: now)
                    Spacer(minLength: 4)
                    if !stale { PaceNote(meter: meter, now: now) }
                }
                .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
            }
        }
        // One element per window: the bar, notch and countdown read as a sentence.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meter.label)
        .accessibilityValue(meter.spokenSummary(at: now) + (stale ? ", may be out of date" : ""))
    }
}

/// Icon + vendor + account, freshness on the right, then each meter.
struct ProviderCard: View {
    var provider: ProviderUsage
    var now: Date
    var compact = false
    /// Popover only: the header opens the vendor's usage page.
    var linksOut = false

    var body: some View {
        let stale = provider.isStale(at: now)
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            header
            if let note = provider.note {
                Label(note, systemImage: provider.meters.isEmpty ? "infinity" : "info.circle")
                    .font(.system(size: compact ? 9.5 : 10.5)).foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if provider.meters.isEmpty {
                Text("No Limits Reported Yet")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            ForEach(provider.meters) { MeterRow(meter: $0, now: now, compact: compact, stale: stale) }
            if !compact, let shares = provider.breakdown, !shares.isEmpty { BreakdownRow(shares: shares) }
            if let extra = provider.extra { ExtraRow(extra: extra, compact: compact) }
        }
    }

    @ViewBuilder private var header: some View {
        if linksOut {
            Link(destination: provider.vendor.usageURL) { headerRow }
                .buttonStyle(.plain)
                .help("Open \(provider.vendor.displayName) usage")
        } else {
            headerRow
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 7) {
            VendorIcon(vendor: provider.vendor, size: compact ? 18 : 22)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(provider.vendor.displayName)
                        .font(.system(size: compact ? 11 : 12, weight: .semibold))
                        .lineLimit(1)
                    if provider.experimental == true {
                        Text("BETA").font(.system(size: 7, weight: .bold))
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.6), lineWidth: 0.5))
                            .foregroundStyle(.secondary)
                            .help("Read from an undocumented source; figures may be approximate.")
                    }
                }
                Text(provider.accountLine)
                    .font(.system(size: compact ? 9 : 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            FreshnessBadge(provider: provider, now: now, compact: compact)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
