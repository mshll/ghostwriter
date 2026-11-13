import Foundation
import GWCore
import os

final class Scheduler {
    struct Submission: Sendable {
        var id: Int
        var request: CompletionRequest
        var ticket: Int
        var continuation: AsyncStream<SuggestionUpdate>.Continuation?
        var submitted: ContinuousClock.Instant
    }

    private enum Relation {
        case same
        case extended(appended: [UInt8], anchor: Int)
        case unrelated
    }

    private let session: Session
    private let abort: AbortSignal
    private let log = Logger.gw("inference")
    private var target: Submission?
    private var targetDone = false
    private var reused = false
    private var search: BeamSearch?
    private var prepared: (id: Int, prompt: PreparedPrompt)?
    private var publications: [Publication] = []
    private var lastPublished: [Candidate] = []
    private var rerankTotals: [[Int32]: Double] = [:]
    private var rerankVersion = -1
    private var midLineScored: [[UInt8]] = []
    var collectsPublications = false
    var lastSubmitted: ContinuousClock.Instant? { target?.submitted }

    init(session: Session, abort: AbortSignal) {
        self.session = session
        self.abort = abort
    }

    func adopt(_ next: Submission) {
        if let target, !targetDone { target.continuation?.finish() }
        target = next
        targetDone = false
        reused = false
        lastPublished = []
        guard let search else { return }
        switch relation(of: next.request, to: search) {
        case .same:
            reused = true
            publishCurrent(of: search)
        case .extended(let appended, let anchor):
            guard next.request.tuning.reusesBeams else { return drop() }
            do {
                guard try search.follow(next.request, appended: appended, anchor: anchor) else { return drop() }
                reused = true
                publishCurrent(of: search)
            } catch {
                log.error("Following typed text failed: \(error.localizedDescription, privacy: .public)")
                drop()
            }
        case .unrelated:
            drop()
        }
    }

    func runUnit() -> Bool {
        guard let target, !targetDone else { return false }
        abort.begin(target.ticket)
        if abort.isCancelled {
            end()
            return false
        }
        do {
            guard let search else {
                try startSearch(for: target)
                return true
            }
            if search.isDone {
                try finish(search)
            } else {
                var batch = streamsMidLine ? pendingRerank(for: search) : nil
                do {
                    let offset = try search.step(extra: batch?.entries ?? [])
                    if let decoded = batch {
                        batch = nil
                        try session.collect(decoded, offset: offset, into: &rerankTotals)
                    }
                } catch {
                    if let batch { session.discard(batch) }
                    drop()
                    throw error
                }
                if search.isDone, target.request.textAfter.isEmpty {
                    try finish(search)
                } else {
                    publishCurrent(of: search)
                }
            }
        } catch is CancellationError {
            end()
        } catch {
            log.error("Continuous completion failed: \(error.localizedDescription, privacy: .public)")
            drop()
            end()
        }
        return true
    }

    /// Drops the search and the target; for callers about to change sequence 0 or the beam sequences.
    func reset() {
        drop()
        prepared = nil
        end()
    }

    func takePublications() -> [Publication] {
        defer { publications = [] }
        return publications
    }

    // MARK: Private

    private func startSearch(for target: Submission) throws {
        if prepared?.id != target.id {
            var stats = GenerationStats()
            prepared = (target.id, session.prepare(prompt: target.request.prompt, partialWord: target.request.partialWord, stats: &stats))
        }
        guard let prompt = prepared?.prompt, !prompt.tokens.isEmpty else { return end() }
        guard try session.prefillChunk(prompt.tokens, abort: abort) else { return }
        prepared = nil
        let search = BeamSearch(session: session, request: target.request, prompt: prompt, abort: abort, parks: target.request.tuning.reusesBeams)
        self.search = search
        midLineScored = []
        try search.start()
        if search.isDone, target.request.textAfter.isEmpty { try finish(search) }
    }

    private func publishCurrent(of search: BeamSearch) {
        let midLine = !(target?.request.textAfter.isEmpty ?? true)
        if search.isDone, !midLine || finalRerankIsScored(search) {
            do {
                try finish(search)
            } catch {
                log.error("Publishing failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        guard target?.request.tuning.reusesBeams == true, !search.isDone else { return }
        var candidates = search.provisional()
        if midLine, let request = target?.request { candidates = keptMidLine(candidates, of: search, request: request) }
        if !candidates.isEmpty, candidates != lastPublished { publish(candidates, final: false) }
    }

    /// The current mid-line candidates and earlier-scored ones that a current candidate still extends, as far as
    /// the rerank has kept them, best gain first. One that ends a sentence waits for the final rerank, which
    /// weighs it against every candidate: inserted text rarely ends one.
    private func keptMidLine(_ current: [Candidate], of search: BeamSearch, request: CompletionRequest) -> [Candidate] {
        guard let plan = session.midLinePlan(current, required: search.required, textAfter: request.textAfter, tuning: request.tuning)
        else { return current }
        resetRerankTotals(for: search)
        var kept = session.kept(plan, totals: rerankTotals, tuning: request.tuning)
        let held = midLineScored.compactMap { bytes -> Candidate? in
            guard bytes.count > search.required.count, bytes.starts(with: search.required) else { return nil }
            let text = TextRules.decodeComplete(bytes[search.required.count...])
            let stem = TextRules.trimmingTrailingWhitespace(text)
            let extended = current.contains {
                $0.text.hasPrefix(stem) && !TextRules.continuesWord(String($0.text.dropFirst(stem.count)))
            }
            guard !stem.isEmpty, extended else { return nil }
            return Candidate(text: text, score: 0)
        }
        var all = request.tuning
        all.midLineCandidates = held.count
        if !held.isEmpty, let heldPlan = session.midLinePlan(held, required: search.required, textAfter: request.textAfter, tuning: all) {
            kept += session.kept(heldPlan, totals: rerankTotals, tuning: request.tuning)
        }
        var seen = Set<String>()
        return kept.sorted { $0.score > $1.score }
            .filter { seen.insert($0.text).inserted && TextRules.sentenceEnd(of: TextRules.trimmingTrailingWhitespace($0.text)) == .none }
            .prefix(max(request.tuning.maxCandidates, 1)).map { $0 }
    }

    private var streamsMidLine: Bool {
        guard let request = target?.request else { return false }
        return !request.textAfter.isEmpty && request.tuning.reusesBeams
    }

    private func pendingRerank(for search: BeamSearch) -> RerankBatch? {
        guard let target, let plan = session.midLinePlan(
            search.provisional(), required: search.required, textAfter: target.request.textAfter, tuning: target.request.tuning
        ), !plan.candidates.isEmpty else { return nil }
        resetRerankTotals(for: search)
        for candidate in plan.candidates {
            let bytes = search.required + Array(candidate.text.utf8)
            if !midLineScored.contains(bytes) { midLineScored.append(bytes) }
        }
        if midLineScored.count > 64 { midLineScored.removeFirst(midLineScored.count - 64) }
        let missing = session.unscored(plan, in: rerankTotals)
        let limit = session.freeSequenceCount - search.sequencesNeeded
        guard !missing.isEmpty, limit > 0 else { return nil }
        return session.rerankBatch(Array(missing.prefix(limit)), room: search.batchRoom)
    }

    private func finalRerankIsScored(_ search: BeamSearch) -> Bool {
        guard let target, let plan = session.midLinePlan(
            search.ranked(), required: search.required, textAfter: target.request.textAfter, tuning: target.request.tuning
        ), !plan.candidates.isEmpty else { return true }
        resetRerankTotals(for: search)
        return session.unscored(plan, in: rerankTotals).isEmpty
    }

    private func resetRerankTotals(for search: BeamSearch) {
        guard rerankVersion != search.rootVersion || rerankTotals.count > 512 else { return }
        rerankTotals = [:]
        rerankVersion = search.rootVersion
    }

    private func finish(_ search: BeamSearch) throws {
        guard let target else { return }
        var candidates = search.ranked()
        if !target.request.textAfter.isEmpty, !candidates.isEmpty {
            resetRerankTotals(for: search)
            candidates = try session.rerankMidLine(
                candidates, required: search.required, textAfter: target.request.textAfter, tuning: target.request.tuning,
                totals: &rerankTotals
            )
        }
        publish(candidates, final: true)
        end()
    }

    private func publish(_ candidates: [Candidate], final: Bool) {
        guard let target else { return }
        let update = SuggestionUpdate(
            candidates: candidates, isFinal: final, milliseconds: target.submitted.duration(to: .now).milliseconds, reused: reused
        )
        target.continuation?.yield(update)
        lastPublished = candidates
        if collectsPublications { publications.append(Publication(request: target.id, update: update)) }
    }

    private func end() {
        targetDone = true
        target?.continuation?.finish()
    }

    private func drop() {
        search?.release()
        search = nil
        midLineScored = []
    }

    private func relation(of request: CompletionRequest, to search: BeamSearch) -> Relation {
        guard search.rootVersion == session.rootVersion, request.mode == .inline, Self.compatible(request, search.request) else {
            return .unrelated
        }
        let current = search.prompt.body + search.required
        let full = Array((request.prompt + request.partialWord).utf8)
        guard full.count >= current.count, full.starts(with: current) else { return .unrelated }
        let anchor = TextRules.splitTrailingSpaces(request.prompt).prompt.utf8.count - search.prompt.body.count
        guard anchor >= 0 else { return .unrelated }
        guard full.count > current.count else { return .same }
        return .extended(appended: Array(full[current.count...]), anchor: anchor)
    }

    private static func compatible(_ a: CompletionRequest, _ b: CompletionRequest) -> Bool {
        a.textAfter == b.textAfter && a.maxWords == b.maxWords && a.mode == b.mode && a.beams == b.beams && a.topK == b.topK
            && a.bias == b.bias && a.tuning == b.tuning && a.stopStrings == b.stopStrings
    }
}
