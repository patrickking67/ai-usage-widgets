import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let board: UsageBoard?
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, board: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: .now, board: context.isPreview ? .placeholder : UsageStore.loadBoard()))
    }

    /// The board changes only when a vendor reports, but countdowns tick
    /// regardless: one entry per minute for 30 minutes from the same file.
    /// The menu-bar app force-reloads whenever the board actually changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let board = UsageStore.loadBoard()
        let now = Date()
        let entries = (0..<30).map { UsageEntry(date: now.addingTimeInterval(Double($0) * 60), board: board) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

// MARK: - Families

/// Small: one line per vendor — icon, hottest window, bar.
struct SmallUsageView: View {
    let entry: UsageEntry

    var body: some View {
        // Three lanes fill a small widget; the rest are in the medium and large sizes.
        let providers = Array((entry.board?.providers ?? []).prefix(3))
        VStack(alignment: .leading, spacing: 10) {
            Text("Usage").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if providers.isEmpty { Empty() }
            ForEach(providers) { p in
                let m = p.hottest(at: entry.date)
                let f = m?.fraction(at: entry.date) ?? 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        VendorIcon(vendor: p.vendor, size: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.vendor.displayName).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                            Text(p.accountLine).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if p.isStale(at: entry.date) {
                            Image(systemName: "clock").font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(m == nil ? "—" : "\(Int((f * 100).rounded()))%")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(p.isStale(at: entry.date) ? .secondary : .primary)
                    }
                    UsageBar(fraction: f, tint: m?.tint(at: entry.date) ?? .secondary, height: 4,
                             pace: p.isStale(at: entry.date) ? nil : m?.elapsedFraction(at: entry.date))
                    if let m {
                        HStack(spacing: 3) {
                            Text(m.label)
                            Text("·")
                            ResetLabel(meter: m, now: entry.date)
                        }
                        .font(.system(size: 8)).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Medium: vendors side by side, every window.
struct MediumUsageView: View {
    let entry: UsageEntry

    var body: some View {
        let providers = entry.board?.providers ?? []
        HStack(alignment: .top, spacing: 16) {
            if providers.isEmpty { Empty() }
            ForEach(providers) { p in
                ProviderCard(provider: p, now: entry.date, compact: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if p.id != providers.last?.id { Divider() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Large: full cards with reset times and freshness.
struct LargeUsageView: View {
    let entry: UsageEntry

    var body: some View {
        let providers = entry.board?.providers ?? []
        VStack(alignment: .leading, spacing: 14) {
            Text("Usage").font(.system(size: 13, weight: .semibold))
            if providers.isEmpty { Empty() }
            ForEach(providers) { p in
                ProviderCard(provider: p, now: entry.date)
                if p.id != providers.last?.id { Divider() }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct Empty: View {
    var body: some View {
        Text("Open TokenMeter to start collecting.")
            .font(.system(size: 10)).foregroundStyle(.secondary)
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: SmallUsageView(entry: entry)
            case .systemLarge: LargeUsageView(entry: entry)
            default:           MediumUsageView(entry: entry)
            }
        }
        .overlay(alignment: .bottomTrailing) { StaleBoardBadge(board: entry.board, now: entry.date) }
        .containerBackground(for: .widget) { Color.clear.background(.background) }
        .widgetURL(dashboardURL)
    }
}

/// Clicking any widget opens the dashboard in the menu-bar app.
let dashboardURL = URL(string: "tokenmeter://dashboard")!

struct LimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TokenMeterLimits", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Limits")
        .description("Every plan window with live countdowns and pace.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Activity widget

/// Medium: the week's chart beside what drove it. Large: plus models and a tip.
struct ActivityWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        Group {
            if let a = entry.board?.activity {
                if family == .systemLarge {
                    VStack(alignment: .leading, spacing: 12) {
                        WeekChart(activity: a, height: 96)
                        DriversList(activity: a, limit: 4, compact: true)
                        ModelsList(activity: a, limit: 3)
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        WeekChart(activity: a, height: 78)
                            .frame(maxWidth: .infinity)
                        DriversList(activity: a, limit: 4, compact: true)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                Text("Open TokenMeter to start reading activity.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) { StaleBoardBadge(board: entry.board, now: entry.date) }
        .containerBackground(for: .widget) { Color.clear.background(.background) }
        .widgetURL(dashboardURL)
    }
}

struct ActivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TokenMeterActivity", provider: UsageProvider()) { entry in
            ActivityWidgetView(entry: entry)
        }
        .configurationDisplayName("Activity")
        .description("Tokens over the last week, and what's using your limits.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Rings widget

/// Small: nested rings. Medium: a ring per lane with its reset.
struct RingsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        Group {
            if family == .systemSmall {
                let lanes = ringLanes(entry.board, limit: 3)
                if lanes.isEmpty { Empty() } else { RingStack(providers: lanes, now: entry.date) }
            } else {
                let lanes = ringLanes(entry.board, limit: 4)
                if lanes.isEmpty { Empty() } else {
                    RingRow(providers: lanes, now: entry.date)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) { StaleBoardBadge(board: entry.board, now: entry.date) }
        .containerBackground(for: .widget) { Color.clear.background(.background) }
        .widgetURL(dashboardURL)
    }
}

struct RingsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TokenMeterRings", provider: UsageProvider()) { entry in
            RingsWidgetView(entry: entry)
        }
        .configurationDisplayName("Rings")
        .description("How much of each plan is used, at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct TokenMeterWidgets: WidgetBundle {
    var body: some Widget {
        RingsWidget()
        LimitsWidget()
        ActivityWidget()
    }
}
