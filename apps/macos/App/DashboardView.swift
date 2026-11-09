import SwiftUI

/// The desktop window: every lane's limits beside a month of activity.
/// The popover is for a glance; this is for working out where the tokens went.
struct DashboardView: View {
    @ObservedObject var collector: Collector
    @State private var now = Date()
    @AppStorage("dashboardSpan") private var span = 30
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    var forcedNow: Date? = nil      // --render

    private var board: UsageBoard? { collector.board }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView { limits.padding(20) }
                .frame(width: 340)
                .background(.background.secondary)
            Divider()
            ScrollView { activity.padding(24) }
                .frame(minWidth: 520, maxWidth: .infinity)
        }
        .frame(minWidth: 880, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Span", selection: $span) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented).fixedSize()
            }
            ToolbarItem {
                Button(action: collector.refreshNow) { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            ToolbarItem {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }
        }
        .onReceive(tick) { now = forcedNow ?? $0 }
        .onAppear { DockPolicy.dashboardOpen = true; DockPolicy.apply() }
        .onDisappear { DockPolicy.dashboardOpen = false; DockPolicy.apply() }
    }

    // MARK: Limits column

    private var limits: some View {
        LimitsColumn(board: board, problems: collector.problems, now: forcedNow ?? now)
    }

    // MARK: Activity

    @ViewBuilder private var activity: some View {
        if let a = board?.activity {
            ActivityDashboard(activity: a, span: span)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading a month of local logs. The first pass takes a minute; later ones are instant.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 400)
        }
    }
}

struct LimitsColumn: View {
    var board: UsageBoard?
    var problems: [Vendor: String]
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Limits").font(.title3.weight(.semibold))
            if let providers = board?.providers, !providers.isEmpty {
                ForEach(providers) { p in
                    VStack(alignment: .leading, spacing: 8) {
                        ProviderCard(provider: p, now: now, linksOut: true)
                        if let problem = problems[p.vendor] {
                            Label(problem, systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator, lineWidth: 0.5))
                }
            } else {
                Text("No lanes reporting yet. Run Claude Code, Codex or Copilot once.")
                    .foregroundStyle(.secondary)
            }
            Text("A notch on a bar marks even pace: past it, you are on course to run out before the reset.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

struct ActivityDashboard: View {
    var activity: Activity
    var span: Int

    private var days: [DayUsage] { Array(activity.days.suffix(span)) }
    private var total: Double { days.reduce(0) { $0 + $1.total } }
    private var busiest: DayUsage? { days.max { $0.total < $1.total } }
    private var activeDays: Int { days.filter { $0.total > 0 }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Stat(title: "Tokens · \(span)d", value: total.compactTokens, detail: trend)
                Stat(title: "Daily average", value: (activeDays > 0 ? total / Double(activeDays) : 0).compactTokens,
                     detail: "\(activeDays) active days")
                Stat(title: "Busiest day", value: busiest.map { $0.total.compactTokens } ?? "–",
                     detail: busiest.map { $0.date.formatted(.dateTime.weekday(.abbreviated).month().day()) })
                Stat(title: "Claude cache hit · 24h",
                     value: activity.claude24h.cacheHit.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
            }
            card { WeekChart(activity: activity, height: 220, span: span) }
            let shares = activity.vendorShares(span: span)
            if shares.count > 1 {
                card { VendorShares(shares: shares, span: span) }
            }
            HStack(alignment: .top, spacing: 16) {
                card { DriversList(activity: activity, limit: 8) }
                card { ModelsList(activity: activity, limit: 8) }
            }
            if activity.projects?.isEmpty == false || activity.heat != nil {
                HStack(alignment: .top, spacing: 16) {
                    if let projects = activity.projects, !projects.isEmpty {
                        card { ProjectsList(projects: projects, limit: 8) }
                    }
                    if let heat = activity.heat {
                        card { HeatMap(heat: heat, peak: activity.peak) }
                    }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                card { BreakdownTable(title: "Claude · last 24h", tokens: activity.claude24h) }
                if activity.codex24h.total > 0 {
                    card { BreakdownTable(title: "Codex · last 24h", tokens: activity.codex24h) }
                }
                if let c = activity.copilot24h, c.total > 0 {
                    card { BreakdownTable(title: "Copilot · last 24h", tokens: c) }
                }
            }
            if let tip = activity.tip { TipCard(text: tip) }
            Text("From local logs on this Mac: Claude Code transcripts, Codex rollouts and VS Code agent sessions. Usage on the web or other machines is not included.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    /// "Up 42% on last week", from the last 14 days whatever the span.
    private var trend: String? {
        guard let w = activity.weekOverWeek else { return nil }
        let pct = Int((abs(w) * 100).rounded())
        return pct == 0 ? "Same as last week" : "\(w > 0 ? "Up" : "Down") \(pct)% on last week"
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct Stat: View {
    var title: String
    var value: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail ?? " ").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Each tool's share of the span: one bar in vendor colours, then the figures.
private struct VendorShares: View {
    var shares: [(vendor: Vendor, tokens: Double, share: Double)]
    var span: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("By tool").font(.headline)
                Spacer()
                Text("\(span)d").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(shares, id: \.vendor) { s in
                        Rectangle().fill(Palette.vendor(s.vendor).gradient)
                            .frame(width: max(geo.size.width * s.share - 2, 3))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            HStack(spacing: 18) {
                ForEach(shares, id: \.vendor) { s in
                    HStack(spacing: 6) {
                        VendorIcon(vendor: s.vendor, size: 14)
                        Text(s.vendor.shortName)
                        Text(s.share < 0.005 ? "<1%" : "\(Int((s.share * 100).rounded()))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                        Text(s.tokens.compactTokens).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    .font(.callout)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tokens by tool, last \(span) days")
        .accessibilityValue(shares.map { "\($0.vendor.displayName) \(Int(($0.share * 100).rounded())) percent" }.joined(separator: ", "))
    }
}

/// Which repositories spent the week's tokens.
private struct ProjectsList: View {
    var projects: [ProjectShare]
    var limit: Int

    var body: some View {
        let top = Array(projects.prefix(limit))
        let most = top.first?.tokens ?? 1
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Projects").font(.headline)
                Spacer()
                Text("7d").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(top) { p in
                HStack(spacing: 8) {
                    VendorIcon(vendor: p.vendor, size: 14)
                    Text(p.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    UsageBar(fraction: p.tokens / most, tint: Palette.vendor(p.vendor), height: 4)
                        .frame(width: 110)
                    Text(p.tokens.compactTokens).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
                .font(.callout)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(p.name)
                .accessibilityValue("\(p.tokens.compactTokens) tokens, mostly \(p.vendor.displayName)")
            }
        }
    }
}

/// Tokens by weekday and hour over the month: when the limits actually go.
private struct HeatMap: View {
    var heat: [[Double]]
    var peak: (weekday: Int, hour: Int)?
    private let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        let top = max(heat.joined().max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("When you work").font(.headline)
                Spacer()
                Text("30d").font(.caption).foregroundStyle(.secondary)
            }
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach(0..<7, id: \.self) { d in
                    GridRow {
                        Text(days[d]).font(.caption2).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
                        ForEach(0..<24, id: \.self) { h in
                            // Square root so a light hour still shows beside a heavy one.
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(heat[d][h] > 0 ? Palette.clay.opacity(0.15 + 0.85 * (heat[d][h] / top).squareRoot())
                                                     : Color.primary.opacity(0.05))
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
                GridRow {
                    Color.clear.frame(width: 26, height: 1)
                    ForEach(0..<24, id: \.self) { h in
                        // Labels hang off their cell so they never widen a column.
                        Color.clear.frame(height: 10).overlay(alignment: .leading) {
                            if h % 6 == 0 {
                                Text(hourLabel(h)).font(.system(size: 8)).foregroundStyle(.tertiary).fixedSize()
                            }
                        }
                    }
                }
            }
            if let peak {
                Text("Busiest: \(days[peak.weekday]) around \(hourLabel(peak.hour))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tokens by weekday and hour, last 30 days")
        .accessibilityValue(peak.map { "Busiest \(days[$0.weekday]) around \(hourLabel($0.hour))" } ?? "")
    }

    private func hourLabel(_ h: Int) -> String {
        var c = DateComponents(); c.hour = h
        let d = Calendar.current.date(from: c) ?? .now
        return d.formatted(.dateTime.hour())
    }
}
