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
                Stat(title: "Tokens · \(span)d", value: total.compactTokens)
                Stat(title: "Daily average", value: (activeDays > 0 ? total / Double(activeDays) : 0).compactTokens,
                     detail: "\(activeDays) active days")
                Stat(title: "Busiest day", value: busiest.map { $0.total.compactTokens } ?? "–",
                     detail: busiest.map { $0.date.formatted(.dateTime.weekday(.abbreviated).month().day()) })
                Stat(title: "Claude cache hit · 24h",
                     value: activity.claude24h.cacheHit.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
            }
            card { WeekChart(activity: activity, height: 220, span: span) }
            HStack(alignment: .top, spacing: 16) {
                card { DriversList(activity: activity, limit: 8) }
                card { ModelsList(activity: activity, limit: 8) }
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
