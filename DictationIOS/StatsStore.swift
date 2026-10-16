import Foundation
import Combine

/// One graded dictation sentence or pronunciation attempt.
nonisolated struct StatsEvent: Codable {
    enum Kind: String, Codable { case dictation, pronunciation }
    let date: Date
    let kind: Kind
    let score: Int
    let missedWords: [String]
}

/// Weekly practice statistics, kept on device.
@MainActor
final class StatsStore: ObservableObject {
    static let shared = StatsStore()

    @Published private(set) var events: [StatsEvent] = []
    private static let key = "practiceStatsEvents"
    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([StatsEvent].self, from: data) {
            events = saved
        }
    }

    func recordDictation(score: Int, missedWords: [String]) {
        record(StatsEvent(date: .now, kind: .dictation, score: score, missedWords: missedWords))
    }

    func recordPronunciation(score: Int) {
        record(StatsEvent(date: .now, kind: .pronunciation, score: score, missedWords: []))
    }

    private func record(_ event: StatsEvent) {
        events.append(event)
        // Two weeks are enough for the weekly view and its comparison.
        let cutoff = calendar.date(byAdding: .day, value: -60, to: .now) ?? .distantPast
        events.removeAll { $0.date < cutoff }
        if let data = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    // MARK: - Weekly summary

    struct Week {
        let start: Date
        let end: Date
        /// Sentences dictated on each day, Monday first.
        let dailyCounts: [Int]
        let activeDays: [Bool]
        let streak: Int
        let sentenceCount: Int
        let accuracy: Int?
        let accuracyChange: Int?
        let pronunciation: Int?
        let wordsToReview: [String]
        let todayIndex: Int
    }

    func week(now: Date = .now) -> Week {
        let cal = calendar
        let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 6, to: start) ?? start
        let previousStart = cal.date(byAdding: .day, value: -7, to: start) ?? start

        let thisWeek = events.filter { $0.date >= start }
        let lastWeek = events.filter { $0.date >= previousStart && $0.date < start }

        var counts = [Int](repeating: 0, count: 7)
        for event in thisWeek where event.kind == .dictation {
            let day = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: event.date)).day ?? 0
            if counts.indices.contains(day) { counts[day] += 1 }
        }
        let todayIndex = min(6, max(0, cal.dateComponents([.day], from: start, to: cal.startOfDay(for: now)).day ?? 0))

        // Consecutive practice days ending today (or yesterday, if today is still empty).
        let practiceDays = Set(events.map { cal.startOfDay(for: $0.date) })
        var day = cal.startOfDay(for: now)
        if !practiceDays.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day) ?? day }
        var streak = 0
        while practiceDays.contains(day) {
            streak += 1
            day = cal.date(byAdding: .day, value: -1, to: day) ?? .distantPast
        }

        func average(_ items: [StatsEvent], _ kind: StatsEvent.Kind) -> Int? {
            let scores = items.filter { $0.kind == kind }.map(\.score)
            guard !scores.isEmpty else { return nil }
            return Int((Double(scores.reduce(0, +)) / Double(scores.count)).rounded())
        }
        let accuracy = average(thisWeek, .dictation)
        let previousAccuracy = average(lastWeek, .dictation)

        // Most-missed words first.
        var misses: [String: (display: String, count: Int)] = [:]
        for word in thisWeek.flatMap(\.missedWords) {
            let key = word.lowercased()
            misses[key] = (misses[key]?.display ?? word, (misses[key]?.count ?? 0) + 1)
        }
        let words = misses.values.sorted { $0.count > $1.count }.map(\.display)

        return Week(
            start: start, end: end,
            dailyCounts: counts,
            activeDays: (0..<7).map { index in
                let date = cal.date(byAdding: .day, value: index, to: start) ?? start
                return practiceDays.contains(date)
            },
            streak: streak,
            sentenceCount: counts.reduce(0, +),
            accuracy: accuracy,
            accuracyChange: accuracy.flatMap { current in previousAccuracy.map { current - $0 } },
            pronunciation: average(thisWeek, .pronunciation),
            wordsToReview: words,
            todayIndex: todayIndex
        )
    }
}
