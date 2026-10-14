import Charts
import GWCore
import Memory
import os
import SwiftUI

struct StatisticsPane: View {
    private static let log = Logger.gw("Statistics")
    private static let wordsPerMinute = 40.0
    private static let days = 30
    private static let appLimit = 10

    @Environment(AppServices.self) private var services
    @State private var daily: [DailyStat] = []
    @State private var apps: [AppStat] = []
    @State private var kinds: [KindStat] = []
    @State private var errorMessage: String?

    var body: some View {
        SettingsPaneView(pane: .statistics) {
            Section {
                if daily.allSatisfy({ $0.wordsAccepted == 0 }) {
                    Text(errorMessage ?? "No accepted suggestions yet. Your progress shows up here.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    WordsChart(stats: daily)
                }
            } header: {
                Text("Last 30 days")
                    .settingsSearchTarget(StatisticsSetting.last30Days)
            }

            Section {
                StatTotals(daily: daily, apps: apps, wordsPerMinute: Self.wordsPerMinute)
            } footer: {
                Text("Time saved assumes \(Int(Self.wordsPerMinute)) words per minute of typing.")
            }

            if !apps.isEmpty {
                Section {
                    ForEach(apps.prefix(Self.appLimit)) { AppStatRow(stat: $0) }
                } header: {
                    Text("By app")
                        .settingsSearchTarget(StatisticsSetting.byApp)
                }
            }

            if !kinds.isEmpty {
                Section {
                    ForEach(kinds) { stat in
                        LabeledContent(stat.kind.title) {
                            Text("^[\(stat.wordsAccepted) word](inflect: true)")
                        }
                    }
                } header: {
                    Text("By kind")
                        .settingsSearchTarget(StatisticsSetting.byKind)
                }
            }
        }
        .task { load() }
    }

    private func load() {
        guard let memory = services.memory else { return }
        do {
            daily = try memory.dailyStats(days: Self.days)
            apps = try memory.appStats(days: Self.days)
            kinds = try memory.kindStats(days: Self.days)
        } catch {
            Self.log.error("Loading statistics failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Statistics couldn\u{2019}t be loaded: \(error.localizedDescription)"
        }
    }
}

private struct WordsChart: View {
    let stats: [DailyStat]

    var body: some View {
        Chart(stats) { stat in
            BarMark(
                x: .value("Day", stat.day, unit: .day),
                y: .value("Words", stat.wordsAccepted)
            )
            .foregroundStyle(.tint)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .frame(height: 180)
        .padding(.vertical, 6)
    }
}

private struct StatTotals: View {
    let daily: [DailyStat]
    let apps: [AppStat]
    let wordsPerMinute: Double

    var body: some View {
        let words = daily.reduce(0) { $0 + $1.wordsAccepted }
        let acceptances = daily.reduce(0) { $0 + $1.acceptances }
        let activeDays = daily.filter { $0.wordsAccepted > 0 }.count
        let saved = Duration.seconds(Double(words) / wordsPerMinute * 60)
        let shown = apps.reduce(0) { $0 + $1.suggestionsShown }
        let used = apps.reduce(0) { $0 + $1.suggestionsUsed }
        row(.words, words.formatted())
        row(.accepted, acceptances.formatted())
        SettingRow(StatisticsSetting.used) {
            Text(UsageRate(shown: shown, used: used).label)
        }
        row(.timeSaved, saved.formatted(.units(allowed: [.hours, .minutes], width: .wide)))
        SettingRow(StatisticsSetting.dailyAverage) {
            Text((activeDays == 0 ? 0 : words / activeDays).formatted())
        }
    }

    private func row(_ key: StatisticsSetting, _ value: String) -> some View {
        SettingRow(key) {
            Text(value)
        }
    }
}

private struct AppStatRow: View {
    let stat: AppStat

    var body: some View {
        LabeledContent {
            Text("^[\(stat.wordsAccepted) word](inflect: true)")
        } label: {
            Label {
                Text(AppInfo.name(for: stat.bundleID))
                Text("Suggestions used: \(UsageRate(shown: stat.suggestionsShown, used: stat.suggestionsUsed).label)")
            } icon: {
                Image(nsImage: AppInfo.icon(for: stat.bundleID))
                    .resizable()
                    .frame(width: 20, height: 20)
            }
        }
    }
}

private struct UsageRate {
    let shown: Int
    let used: Int

    var label: String {
        guard shown > 0 else { return "Not counted yet" }
        let rate = Double(min(used, shown)) / Double(shown)
        return "\(rate.formatted(.percent.precision(.fractionLength(0)))) of \(shown.formatted())"
    }
}

extension AcceptanceEvent.Kind {
    fileprivate var title: String {
        switch self {
        case .full: "Whole suggestions"
        case .word: "Next word"
        case .draft: "Longer drafts"
        case .typo: "Typo fixes"
        case .emoji: "Emoji"
        case .snippet: "Snippets"
        case .action: "Selection actions"
        }
    }
}

enum StatisticsSetting: SettingKey {
    case last30Days, words, accepted, used, timeSaved, dailyAverage, byApp, byKind

    var text: SettingText {
        switch self {
        case .last30Days: SettingText("Last 30 days", keywords: ["chart", "history"])
        case .words: SettingText("Words written for you", keywords: ["count"])
        case .accepted: SettingText("Suggestions accepted")
        case .used: SettingText("Suggestions used", subtitle: "Shown suggestions you took at least one word from.")
        case .timeSaved: SettingText("Estimated time saved")
        case .dailyAverage: SettingText("Daily average", subtitle: "Words per day, counting only days with a suggestion accepted.")
        case .byApp: SettingText("By app")
        case .byKind: SettingText("By kind")
        }
    }
}
