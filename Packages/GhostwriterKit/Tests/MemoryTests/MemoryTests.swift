import Foundation
import GRDB
import GWCore
import Testing
@testable import Memory

let day: TimeInterval = 24 * 3_600

let topics = [
    "We hiked up the ridge trail early in the morning and the views over the valley were spectacular all the way.",
    "The new espresso machine in the kitchen finally works, although the grinder still makes a terrible noise daily.",
    "My sister adopted a small grey kitten, who now sleeps on the piano and chases every shadow across the floor.",
    "Our train to the coast was delayed twice, so we played cards in the station cafe and watched the rain pour.",
    "Gardening this spring went well: tomatoes, basil and peppers are thriving in the raised beds near the fence.",
]

func session(_ key: String, _ text: String, app: String = "com.apple.mail", language: String? = "en", age: TimeInterval = 0) -> WritingSession {
    WritingSession(key: key, bundleID: app, text: text, language: language, updatedAt: Date.now.addingTimeInterval(-age))
}

@Suite struct Sessions {
    @Test func upsertReplacesTheTextForTheSameKey() throws {
        let store = try MemoryStore.inMemory()
        try store.upsertSession(session("field-1", "The quarterly budget forecast needs another pass before Friday's review with finance and the leadership team."))
        try store.upsertSession(session("field-1", topics[0]))
        #expect(try store.writingCount(bundleID: nil) == 1)
        let found = try store.examples(query: "quarterly budget forecast", bundleID: "com.apple.mail", language: nil, limit: 3, excludingKey: nil)
        #expect(found == [topics[0]])
    }

    @Test func eraseRemovesOneAppOrEverything() throws {
        let store = try MemoryStore.inMemory()
        try store.upsertSession(session("a", topics[0], app: "com.apple.mail"))
        try store.upsertSession(session("b", topics[1], app: "com.tinyspeck.slackmacgap"))
        try store.upsertSession(session("c", topics[2], app: "com.tinyspeck.slackmacgap"))
        #expect(try store.writingCount(bundleID: "com.tinyspeck.slackmacgap") == 2)
        try store.eraseWriting(bundleID: "com.tinyspeck.slackmacgap")
        #expect(try store.writingCount(bundleID: nil) == 1)
        try store.eraseWriting(bundleID: nil)
        #expect(try store.writingCount(bundleID: nil) == 0)
        #expect(try store.examples(query: "ridge trail", bundleID: "com.apple.mail", language: nil, limit: 3, excludingKey: nil).isEmpty)
    }

    @Test func eraseLeavesNoTraceInTheDatabaseFiles() throws {
        let folder = URL.temporaryDirectory.appending(path: "memory-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            do { try FileManager.default.removeItem(at: folder) } catch { Issue.record(error) }
        }
        let url = folder.appending(path: "store.sqlite")
        let files = [url, URL(filePath: url.path(percentEncoded: false) + "-wal")]
        func contains(_ word: String) throws -> Bool {
            try files.contains { file in
                guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return false }
                return try Data(contentsOf: file).range(of: Data(word.utf8)) != nil
            }
        }
        let store = try MemoryStore(url: url)
        try store.upsertSession(session("private", topics[0] + " The zygomorphicquokka plan stays private.", app: "com.apple.Notes"))
        for (index, text) in topics.enumerated() { try store.upsertSession(session("t\(index)", text)) }
        #expect(try contains("zygomorphicquokka"))
        try store.eraseWriting(bundleID: "com.apple.Notes")
        #expect(try !contains("zygomorphicquokka"))
        #expect(try !contains("quokka"))
        #expect(try store.writingCount(bundleID: nil) == topics.count)
    }

    @Test func fileStoreCreatesItsFolderAndKeepsData() throws {
        let folder = URL.temporaryDirectory.appending(path: "memory-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            do { try FileManager.default.removeItem(at: folder) } catch { Issue.record(error) }
        }
        let url = folder.appending(path: "nested/store.sqlite")
        try MemoryStore(url: url).upsertSession(session("a", topics[0]))
        #expect(try MemoryStore(url: url).writingCount(bundleID: nil) == 1)
    }
}

@Suite struct Retention {
    @Test func sessionsOlderThanTheMaximumAgeArePurged() throws {
        let store = try MemoryStore.inMemory()
        try store.upsertSession(session("old", topics[0], age: 100 * day))
        try store.upsertSession(session("recent", topics[1], age: 10 * day))
        try store.purge(now: .now)
        #expect(try store.writingCount(bundleID: nil) == 1)
        #expect(try store.examples(query: "", bundleID: "com.apple.mail", language: nil, limit: 5, excludingKey: nil) == [topics[1]])
    }

    @Test func theOldestSessionsGoFirstWhenOverTheCap() throws {
        var retention = MemoryStore.Retention()
        retention.maxSessions = 3
        let store = try MemoryStore.inMemory(retention: retention)
        for (index, text) in topics.enumerated() {
            try store.upsertSession(session("s\(index)", text, age: Double(topics.count - index) * day))
        }
        try store.purge(now: .now)
        let kept = try store.examples(query: "", bundleID: "com.apple.mail", language: nil, limit: 5, excludingKey: nil)
        #expect(kept == [topics[4], topics[3], topics[2]])
    }

    @Test func acceptanceEventsOlderThanTheLimitArePurged() throws {
        let store = try MemoryStore.inMemory()
        for age in [401.0, 399.0] {
            try store.recordAcceptance(AcceptanceEvent(
                kind: .word, bundleID: "a", words: 1, characters: 4, date: .now.addingTimeInterval(-age * day)
            ))
        }
        try store.purge(now: .now)
        #expect(try store.dailyStats(days: 500).map(\.acceptances).reduce(0, +) == 1)
    }

    @Test func suggestionCountsOlderThanTheLimitArePurged() throws {
        let store = try MemoryStore.inMemory()
        for age in [401.0, 399.0] {
            try store.recordSuggestion(.shown, bundleID: "a", date: .now.addingTimeInterval(-age * day))
        }
        try store.purge(now: .now)
        #expect(try store.appStats(days: 500).map(\.suggestionsShown) == [1])
    }
}

@Suite struct Retrieval {
    let budget = """
        Hi Dana, I went through the quarterly budget forecast again and the marketing spend for the spring campaign \
        still looks too high compared with last year, so let us trim it before the review.
        """

    @Test func aRelevantPassageBeatsRecentIrrelevantWriting() throws {
        let store = try MemoryStore.inMemory()
        try store.upsertSession(session("budget", budget, age: 20 * day))
        for (index, text) in topics.enumerated() { try store.upsertSession(session("t\(index)", text)) }
        let found = try store.examples(
            query: "Thanks for sending the updated forecast. About the marketing", bundleID: "com.apple.mail",
            language: "en", limit: 2, excludingKey: nil
        )
        #expect(found.first == budget)
    }

    @Test func theSameAppRanksFirstAmongEqualMatches() throws {
        let store = try MemoryStore.inMemory()
        let mail = "The invoice for the design work is attached, please confirm the payment date when you have a moment."
        let notes = "The invoice for the logo work arrived, remember to confirm the payment date with accounting this week."
        try store.upsertSession(session("notes", notes, app: "com.apple.Notes"))
        try store.upsertSession(session("mail", mail, app: "com.apple.mail", age: day))
        let found = try store.examples(query: "invoice payment", bundleID: "com.apple.mail", language: nil, limit: 2, excludingKey: nil)
        #expect(found == [mail, notes])
    }

    @Test func theLanguageFilterKeepsOtherLanguagesOut() throws {
        let store = try MemoryStore.inMemory()
        let german = "Der Zeitplan für das Projekt ist sehr knapp, deshalb sollten wir die Meilensteine nächste Woche gemeinsam prüfen."
        let english = "The Projekt Zeitplan document lists every milestone, and I translated the headings for the whole team today."
        try store.upsertSession(session("de", german, language: "de"))
        try store.upsertSession(session("en", english, language: "en"))
        let found = try store.examples(query: "Projekt Zeitplan", bundleID: "com.apple.mail", language: "de", limit: 5, excludingKey: nil)
        #expect(found == [german])
    }

    @Test func excludedKeysAndShortTextsAreSkipped() throws {
        let store = try MemoryStore.inMemory()
        try store.upsertSession(session("current", budget))
        try store.upsertSession(session("short", "Budget forecast is fine."))
        let found = try store.examples(query: "budget forecast", bundleID: "com.apple.mail", language: nil, limit: 5, excludingKey: "current")
        #expect(found.isEmpty)
    }

    @Test func anEmptyQueryReturnsRecentWritingFromTheSameAppFirst() throws {
        let store = try MemoryStore.inMemory()
        try store.upsertSession(session("other", topics[0], app: "com.apple.Notes"))
        try store.upsertSession(session("old", topics[1], age: 5 * day))
        try store.upsertSession(session("new", topics[2], age: day))
        let found = try store.examples(query: "the and of", bundleID: "com.apple.mail", language: nil, limit: 3, excludingKey: nil)
        #expect(found == [topics[2], topics[1], topics[0]])
    }

    @Test func nearIdenticalPassagesAppearOnce() throws {
        let store = try MemoryStore.inMemory()
        try store.upsertSession(session("a", budget))
        try store.upsertSession(session("b", budget + " Thanks!"))
        let found = try store.examples(query: "budget forecast", bundleID: "com.apple.mail", language: nil, limit: 5, excludingKey: nil)
        #expect(found.count == 1)
    }

    @Test func longTextsYieldTheDensestSentenceWindow() throws {
        let filler = topics.joined(separator: " ")
        let target = "The quarterly forecast spreadsheet needs one more review from finance."
        let text = filler + " " + filler + " " + target + " " + filler + " " + filler
        let store = try MemoryStore.inMemory()
        try store.upsertSession(session("long", text))
        let found = try store.examples(query: "quarterly forecast spreadsheet", bundleID: "com.apple.mail", language: nil, limit: 1, excludingKey: nil)
        let passage = try #require(found.first)
        #expect(passage.contains(target))
        #expect(passage.count <= Passages.length + 2 * Passages.reach)
        #expect(passage.count >= Passages.length - 20)
        #expect(passage.first?.isUppercase == true)
        #expect(passage.last == ".")
    }

    let chineseBudget = """
        我们需要在周五之前重新检查下个季度的预算预测，市场部门的春季推广费用仍然偏高，所以请财务团队在评审会议之前\
        把这部分开支再削减一些，并且准备一份新的对比表格，方便领导在会上快速比较去年和今年的数字。谢谢。
        """
    let chineseTrip = """
        我们坐火车去海边的那天下了一整天的雨，车站的咖啡馆里坐满了等车的旅客，我们只好一边打牌一边看着窗外的雨水，\
        晚上终于到了酒店，大家都累坏了，第二天早上我们去看了日出，风景非常美丽，回来以后每个人都晒黑了。
        """

    @Test func textWithoutSpacesMatchesByCharacterPairs() throws {
        let store = try MemoryStore.inMemory()
        try store.upsertSession(session("budget", chineseBudget, language: "zh-Hans", age: 20 * day))
        try store.upsertSession(session("trip", chineseTrip, language: "zh-Hans"))
        let found = try store.examples(query: "关于下个季度的预算", bundleID: "com.apple.mail", language: nil, limit: 2, excludingKey: nil)
        #expect(found == [chineseBudget])
    }

    @Test func upgradingIndexesCharacterPairsOfEarlierWriting() throws {
        let queue = try DatabaseQueue(configuration: MemoryStore.configuration)
        try Schema.migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO writing_sessions (key, bundleID, text, language, updatedAt, createdAt)
                    VALUES ('budget', 'com.apple.mail', ?, 'zh-Hans', ?, ?), ('trip', 'com.apple.mail', ?, 'zh-Hans', ?, ?)
                    """,
                arguments: [chineseBudget, Date.now - 20 * day, Date.now - 20 * day, chineseTrip, Date.now, Date.now]
            )
        }
        let store = try MemoryStore(writer: queue)
        let found = try store.examples(query: "关于下个季度的预算", bundleID: "com.apple.mail", language: nil, limit: 2, excludingKey: nil)
        #expect(found == [chineseBudget])
    }

    @Test func searchTermsCutTextWithoutSpacesIntoCharacterPairs() {
        #expect(SearchTerms(query: "明日の会議").words == ["明日", "日の", "の会", "会議"])
        #expect(SearchTerms(query: "Swiftで会議").words == ["swift", "で会", "会議"])
        #expect(Words.indexedBigrams(in: "Plain English only.").isEmpty)
        #expect(Words.indexedBigrams(in: "Swiftで会議 and more") == "swift で会 会議")
    }

    @Test func searchTermsDropStopwordsShortWordsAndNumbers() {
        let terms = SearchTerms(query: "Hi Anna, the 2026 Café menu and the café prices for us")
        #expect(terms.words == ["anna", "menu", "cafe", "prices"])
        #expect(terms.pattern == "\"anna\" OR \"menu\" OR \"cafe\" OR \"prices\"")
    }
}

@Suite struct Stats {
    let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    func date(_ text: String) throws -> Date {
        try Date(text, strategy: .iso8601)
    }

    @Test func daysAreBucketedLocallyAndGapsAreZero() throws {
        let store = try MemoryStore.inMemory(retention: .init(), calendar: utc)
        try store.recordAcceptance(AcceptanceEvent(kind: .word, bundleID: "a", words: 3, characters: 15, date: date("2026-10-09T10:00:00Z")))
        try store.recordAcceptance(AcceptanceEvent(kind: .full, bundleID: "a", words: 2, characters: 9, date: date("2026-10-09T23:30:00Z")))
        try store.recordAcceptance(AcceptanceEvent(kind: .word, bundleID: "b", words: 4, characters: 20, date: date("2026-10-11T08:00:00Z")))
        let stats = try store.dailyStats(days: 3, now: date("2026-10-11T12:00:00Z"))
        #expect(stats.map(\.day) == [try date("2026-10-09T00:00:00Z"), try date("2026-10-10T00:00:00Z"), try date("2026-10-11T00:00:00Z")])
        #expect(stats.map(\.wordsAccepted) == [5, 0, 4])
        #expect(stats.map(\.charactersAccepted) == [24, 0, 20])
        #expect(stats.map(\.acceptances) == [2, 0, 1])
        #expect(try store.wordsAccepted(on: date("2026-10-11T20:00:00Z")) == 4)
    }

    @Test func appStatsJoinAcceptancesAndSuggestionCountsWithinTheRange() throws {
        let store = try MemoryStore.inMemory(retention: .init(), calendar: utc)
        try store.recordAcceptance(AcceptanceEvent(kind: .word, bundleID: "mail", words: 2, characters: 9, date: date("2026-10-11T09:00:00Z")))
        try store.recordAcceptance(AcceptanceEvent(kind: .full, bundleID: "mail", words: 5, characters: 30, date: date("2026-10-10T09:00:00Z")))
        try store.recordAcceptance(AcceptanceEvent(kind: .full, bundleID: "notes", words: 3, characters: 15, date: date("2026-10-11T09:00:00Z")))
        try store.recordAcceptance(AcceptanceEvent(kind: .full, bundleID: "notes", words: 9, characters: 45, date: date("2026-10-08T09:00:00Z")))
        for _ in 0..<4 { try store.recordSuggestion(.shown, bundleID: "mail", date: date("2026-10-11T09:00:00Z")) }
        try store.recordSuggestion(.used, bundleID: "mail", date: date("2026-10-11T09:00:00Z"))
        try store.recordSuggestion(.shown, bundleID: "slack", date: date("2026-10-10T09:00:00Z"))
        let stats = try store.appStats(days: 2, now: date("2026-10-11T12:00:00Z"))
        #expect(stats == [
            AppStat(bundleID: "mail", wordsAccepted: 7, acceptances: 2, suggestionsShown: 4, suggestionsUsed: 1),
            AppStat(bundleID: "notes", wordsAccepted: 3, acceptances: 1, suggestionsShown: 0, suggestionsUsed: 0),
            AppStat(bundleID: "slack", wordsAccepted: 0, acceptances: 0, suggestionsShown: 1, suggestionsUsed: 0),
        ])
    }

    @Test func kindStatsSumEachKindMostWordsFirst() throws {
        let store = try MemoryStore.inMemory(retention: .init(), calendar: utc)
        try store.recordAcceptance(AcceptanceEvent(kind: .word, bundleID: "a", words: 1, characters: 4, date: date("2026-10-11T09:00:00Z")))
        try store.recordAcceptance(AcceptanceEvent(kind: .word, bundleID: "b", words: 1, characters: 5, date: date("2026-10-11T10:00:00Z")))
        try store.recordAcceptance(AcceptanceEvent(kind: .full, bundleID: "a", words: 6, characters: 30, date: date("2026-10-11T11:00:00Z")))
        let stats = try store.kindStats(days: 1, now: date("2026-10-11T12:00:00Z"))
        #expect(stats == [
            KindStat(kind: .full, wordsAccepted: 6, acceptances: 1),
            KindStat(kind: .word, wordsAccepted: 2, acceptances: 2),
        ])
    }

    @Test func theLocalTimeZoneDecidesTheDay() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let store = try MemoryStore.inMemory(retention: .init(), calendar: newYork)
        try store.recordAcceptance(AcceptanceEvent(kind: .word, bundleID: "a", words: 7, characters: 30, date: date("2026-10-11T02:00:00Z")))
        let stats = try store.dailyStats(days: 2, now: date("2026-10-11T16:00:00Z"))
        #expect(stats.map(\.wordsAccepted) == [7, 0])
    }
}

@Suite struct Settings {
    @Test func snippetTriggersAreUnique() throws {
        let store = try MemoryStore.inMemory()
        var address = Snippet(trigger: ";addr", body: "1 Main Street")
        try store.save(address)
        #expect(throws: MemoryError.duplicateSnippetTrigger(";addr")) {
            try store.save(Snippet(trigger: ";addr", body: "Other"))
        }
        address.body = "2 Main Street"
        address.isEnabled = false
        try store.save(address)
        #expect(try store.snippets() == [address])
        try store.deleteSnippet(id: address.id)
        #expect(try store.snippets().isEmpty)
    }

    @Test func appRulesRoundTrip() throws {
        let store = try MemoryStore.inMemory()
        let mail = AppRule(bundleID: "com.apple.mail", completionsEnabled: false, insertionMode: .keystrokes(chunkSize: 5), customInstructions: "Be brief.")
        var slack = AppRule(bundleID: "com.tinyspeck.slackmacgap", midLineEnabled: true, insertionMode: .paste)
        try store.save(slack)
        try store.save(mail)
        #expect(try store.appRules() == [mail, slack])
        slack.tabAcceptEnabled = false
        try store.save(slack)
        try store.deleteRule(bundleID: "com.apple.mail")
        #expect(try store.appRules() == [slack])
    }
}

@Suite struct Followers {
    @Test func bigramsAreCountedWithinSentencesAndNormalized() throws {
        let store = try MemoryStore.inMemory()
        try store.upsertSession(session("a", "Thank you so much for the help. Thank you so much again. I said thank you twice. Room 4 is free. Room 4 is free."))
        let table = try store.followers(language: nil, limit: 3)
        #expect(table["thank"] == ["you": 1.0])
        #expect(table["you"] == ["so": 2.0 / 3.0])
        #expect(table["is"] == ["free": 1.0])
        #expect(table["help"] == nil)
        #expect(table["room"] == nil)
    }

    @Test func theLimitCapsFollowersPerWord() throws {
        let store = try MemoryStore.inMemory()
        try store.upsertSession(session("a", "go home. go home. go home. go out. go out. go away. go away."))
        #expect(try store.followers(language: nil, limit: 1)["go"] == ["home": 3.0 / 7.0])
    }

    @Test func languageSelectsTheSessions() throws {
        let store = try MemoryStore.inMemory()
        try store.upsertSession(session("en", "good morning. good morning.", language: "en"))
        try store.upsertSession(session("de", "guten morgen. guten morgen.", language: "de"))
        let german = try store.followers(language: "de", limit: 3)
        #expect(german["guten"] == ["morgen": 1.0])
        #expect(german["good"] == nil)
    }

    @Test func newWritingInvalidatesTheCache() throws {
        let store = try MemoryStore.inMemory()
        try store.upsertSession(session("a", "see you soon. see you soon."))
        #expect(try store.followers(language: nil, limit: 3)["you"] == ["soon": 1.0])
        try store.upsertSession(session("b", "see you later. see you later. see you later."))
        #expect(try store.followers(language: nil, limit: 3)["you"] == ["later": 0.6, "soon": 0.4])
    }
}

@Suite struct KnownWordTests {
    @Test func countsSessionsContainingAWord() throws {
        let store = try MemoryStore.inMemory()
        try store.upsertSession(session("a", "Shipping the Kubernetes change today."))
        try store.upsertSession(session("b", "kubernetes is down again"))
        try store.upsertSession(session("c", "Nothing related here."))
        #expect(try store.sessionCount(containing: "Kubernetes") == 2)
        #expect(try store.sessionCount(containing: "tomorow") == 0)
    }

    @Test func toleratesQuotesAndApostrophes() throws {
        let store = try MemoryStore.inMemory()
        try store.upsertSession(session("a", "We don't ship on Fridays."))
        #expect(try store.sessionCount(containing: "don't") == 1)
        #expect(try store.sessionCount(containing: "say \"hi") == 0)
    }
}
