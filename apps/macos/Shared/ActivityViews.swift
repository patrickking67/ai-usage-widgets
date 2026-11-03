import Charts
import SwiftUI
import WidgetKit

// Shared by the popover's Activity tab and the Activity widget.

private func vendorColor(_ v: Vendor, vibrant: Bool) -> Color {
    // Without colour the vendors must still separate: by brightness.
    if vibrant {
        let steps: [Vendor: Double] = [.claude: 1, .codex: 0.45, .copilot: 0.7, .cursor: 0.3, .grok: 0.85]
        return .primary.opacity(steps[v] ?? 0.5)
    }
    return Palette.vendor(v)
}

private struct SectionTitle: View {
    var title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

// MARK: - Daily chart (7 or 30 days)

struct WeekChart: View {
    var activity: Activity
    var height: CGFloat = 110
    var showsTitle = true
    var span = 7
    private var vibrant = IsVibrant()

    init(activity: Activity, height: CGFloat = 110, showsTitle: Bool = true, span: Int = 7) {
        self.activity = activity; self.height = height; self.showsTitle = showsTitle; self.span = span
    }

    private struct Bar: Identifiable {
        var id: String { "\(day.timeIntervalSince1970)-\(vendor.rawValue)" }
        var day: Date, vendor: Vendor, tokens: Double
    }

    private var days: [DayUsage] { Array(activity.days.suffix(span)) }
    private var vendors: [Vendor] { activity.vendors.isEmpty ? [.claude] : activity.vendors }

    private var bars: [Bar] {
        days.flatMap { d in vendors.map { Bar(day: d.date, vendor: $0, tokens: d.tokens($0)) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle {
                SectionTitle(title: "Last \(span) days",
                             trailing: "\(days.reduce(0) { $0 + $1.total }.compactTokens) tokens")
            }
            Chart(bars) { b in
                BarMark(x: .value("Day", b.day, unit: .day), y: .value("Tokens", b.tokens))
                    .foregroundStyle(by: .value("Vendor", b.vendor.displayName))
                    .cornerRadius(span > 7 ? 1 : 2)
            }
            .chartForegroundStyleScale(domain: vendors.map(\.displayName),
                                       range: vendors.map { vendorColor($0, vibrant: vibrant.wrappedValue) })
            .chartLegend(.hidden)
            .chartXAxis {
                if span > 7 {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                } else {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(.primary.opacity(0.08))
                    AxisValueLabel { if let d = v.as(Double.self) { Text(d.compactTokens) } }
                }
            }
            .frame(height: height)
            .widgetAccentable()
            Legend(vendors: vendors, vibrant: vibrant.wrappedValue)
        }
    }

    private struct Legend: View {
        var vendors: [Vendor]
        var vibrant: Bool
        var body: some View {
            HStack(spacing: 10) {
                ForEach(vendors, id: \.self) { v in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(vendorColor(v, vibrant: vibrant)).frame(width: 8, height: 8)
                        Text(v.displayName)
                    }
                }
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 24h breakdown

struct BreakdownTable: View {
    var title: String
    var tokens: TokenBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: title, trailing: tokens.cacheHit.map { "Cache hit \(Int(($0 * 100).rounded()))%" })
                .padding(.bottom, 4)
            row("Input", tokens.input)
            row("Output", tokens.output)
            row("Cache read", tokens.cacheRead)
            row("Cache write", tokens.cacheWrite)
            row("Requests", tokens.requests, divider: false)
        }
    }

    private func row(_ label: String, _ v: Double, divider: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(v.compactTokens).monospacedDigit()
            }
            .font(.system(size: 10.5))
            .padding(.vertical, 3.5)
            if divider { Divider().opacity(0.5) }
        }
    }
}

// MARK: - What's using the limits

struct DriversList: View {
    var activity: Activity
    var limit: Int = 5
    var compact = false
    private var vibrant = IsVibrant()

    init(activity: Activity, limit: Int = 5, compact: Bool = false) {
        self.activity = activity; self.limit = limit; self.compact = compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            SectionTitle(title: compact ? "Using your limits · 24h" : "What's using your limits?",
                         trailing: compact ? nil : "24h")
            if !compact {
                Text("Last 24h · approximate, overlapping · this machine only, not claude.ai")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                insight(activity.longContextShare, "ran above 150k context")
                insight(activity.subagentShare, "came from subagents")
            }
            if activity.drivers.isEmpty {
                Text("No MCP servers, skills or subagents used in the last 24h.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            ForEach(activity.drivers.prefix(limit)) { d in
                if compact {
                    // Narrow: name and share on one line, a hairline bar under it.
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(d.name).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 2)
                            Text("\(Int((d.share * 100).rounded()))%").monospacedDigit()
                        }
                        .font(.system(size: 10))
                        UsageBar(fraction: d.share, tint: Palette.cyan, height: 2.5)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(d.name).lineLimit(1).truncationMode(.middle)
                        Text(d.kind).foregroundStyle(.tertiary).lineLimit(1).layoutPriority(-1)
                        Spacer(minLength: 4)
                        UsageBar(fraction: d.share, tint: Palette.cyan, height: 4).frame(width: 80)
                        Text("\(Int((d.share * 100).rounded()))%")
                            .monospacedDigit().frame(width: 30, alignment: .trailing)
                    }
                    .font(.system(size: 10.5))
                }
            }
        }
    }

    @ViewBuilder private func insight(_ share: Double?, _ text: String) -> some View {
        if let share, share >= 0.05 {
            HStack(spacing: 6) {
                Text("\(Int((share * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(share >= 0.5 ? Palette.amber : .primary)
                Text(text).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Tokens by model

struct ModelsList: View {
    var activity: Activity
    var limit: Int = 5

    var body: some View {
        let top = Array(activity.models.prefix(limit))
        let maxTokens = top.first?.tokens ?? 1
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Tokens by model", trailing: "7d")
            ForEach(top) { m in
                HStack(spacing: 6) {
                    VendorIcon(vendor: m.vendor, size: 12)
                    Text(m.displayName).lineLimit(1)
                    Spacer(minLength: 4)
                    UsageBar(fraction: m.tokens / maxTokens,
                             tint: Palette.vendor(m.vendor), height: 4)
                        .frame(width: 70)
                    Text(m.tokens.compactTokens).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .font(.system(size: 10.5))
            }
        }
    }
}

// MARK: - Tip

struct TipCard: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "lightbulb").foregroundStyle(Palette.amber).widgetAccentable()
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Whole panel (popover)

struct ActivityPanel: View {
    var activity: Activity?
    @State private var showAll = false

    var body: some View {
        if let a = activity {
            VStack(alignment: .leading, spacing: 16) {
                WeekChart(activity: a)
                Divider()
                DriversList(activity: a, limit: showAll ? 12 : 5)
                if a.drivers.count > 5 {
                    Button(showAll ? "Show less" : "Show \(min(a.drivers.count, 12) - 5) more") { showAll.toggle() }
                        .buttonStyle(.borderless).font(.system(size: 10)).padding(.top, -8)
                }
                Divider()
                BreakdownTable(title: "Claude · last 24h", tokens: a.claude24h)
                if a.codex24h.total > 0 { BreakdownTable(title: "Codex · last 24h", tokens: a.codex24h) }
                if let c = a.copilot24h, c.total > 0 { BreakdownTable(title: "Copilot · last 24h", tokens: c) }
                Divider()
                ModelsList(activity: a)
                if let tip = a.tip { TipCard(text: tip) }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading local Claude Code, Codex and VS Code logs… the first pass takes about 20 seconds.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 20)
        }
    }
}
