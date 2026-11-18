import Foundation
import Testing
@testable import Capture

@Suite struct OrcaFocusTests {
    private static func pane(_ handles: [String], active: String) -> [String: Any] {
        guard handles.count > 1 else { return ["type": "terminal", "handle": handles[0], "active": handles[0] == active] }
        return [
            "type": "pane-split", "direction": "vertical",
            "first": pane([handles[0]], active: active), "second": pane(Array(handles.dropFirst()), active: active),
        ]
    }

    /// Each tab lists its panes. The tab that holds `shown` is the active one, with `shown` as its active pane.
    private static func group(_ tabs: [[String]], shown: String) -> [String: Any] {
        [
            "type": "group",
            "activeTabId": "tab-\(tabs.first { $0.contains(shown) }?[0] ?? "")",
            "tabs": tabs.map { panes in
                ["tabId": "tab-\(panes[0])", "panes": pane(panes, active: panes.contains(shown) ? shown : panes[0])]
            },
        ]
    }

    private static func listing(
        _ roots: [[String: Any]], ungrouped: [String] = [], inputs: [String: Double] = [:]
    ) throws -> OrcaFocus.Listing {
        func handles(_ node: [String: Any]) -> [String] {
            if let handle = node["handle"] as? String { return [handle] }
            let tabs = (node["tabs"] as? [[String: Any]] ?? []).compactMap { $0["panes"] as? [String: Any] }
            let halves = [node["first"], node["second"]].compactMap { $0 as? [String: Any] }
            return (tabs + halves).flatMap(handles)
        }
        let all = roots.flatMap(handles) + ungrouped
        let json: [String: Any] = [
            "terminals": all.map { handle in
                let lastInputAt: Any = inputs[handle] ?? NSNull()
                return ["handle": handle, "attention": ["shownRemotely": false, "lastInputAt": lastInputAt]]
            },
            "visualLayouts": roots.map { ["worktreeId": "worktree", "root": $0] },
        ]
        return try JSONDecoder().decode(OrcaFocus.Listing.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func decodesOrcasReply() throws {
        let reply = """
        {"terminals":[{"handle":"term_a","title":"Terminal 1","attention":{"shownRemotely":false,"lastInputAt":null}}],
         "visualLayouts":[{"worktreeId":"w","worktreePath":"/Users/me","root":{"type":"group","groupId":"g",
           "activeTabId":"t1","tabs":[{"tabId":"t1","title":"Terminal 1","activeLeafId":"l1",
           "panes":{"type":"terminal","handle":"term_a","tabId":"t1","leafId":"l1","active":true}}]}}],
         "totalCount":1,"truncated":false}
        """
        let listing = try JSONDecoder().decode(OrcaFocus.Listing.self, from: Data(reply.utf8))
        #expect(listing.groups == [OrcaFocus.Group(handles: ["term_a"], shown: "term_a")])
    }

    @Test func withoutInputPicksTheShownPaneOfTheOnlyGroup() throws {
        var focus = OrcaFocus()
        let listing = try Self.listing([Self.group([["a"], ["b", "c"]], shown: "c")])
        #expect(focus.handle(for: 1, in: listing) == "c")
    }

    @Test func withoutInputAndSeveralGroupsPicksNothing() throws {
        var focus = OrcaFocus()
        let listing = try Self.listing([Self.group([["a"]], shown: "a"), Self.group([["b"]], shown: "b")])
        #expect(focus.handle(for: 1, in: listing) == nil)
    }

    @Test func followsATabSwitchInTheWorkspaceTypedIn() throws {
        var focus = OrcaFocus()
        let listing = try Self.listing(
            [Self.group([["a"], ["b"]], shown: "b"), Self.group([["c"]], shown: "c")], inputs: ["a": 1, "c": 0]
        )
        #expect(focus.handle(for: 1, in: listing) == "b")
    }

    @Test func picksATerminalNoGroupShows() throws {
        var focus = OrcaFocus()
        let listing = try Self.listing([Self.group([["a"]], shown: "a")], ungrouped: ["floating"], inputs: ["floating": 1])
        #expect(focus.handle(for: 1, in: listing) == "floating")
    }

    @Test func returnsToTheTerminalTypedInFromTheSameField() throws {
        var focus = OrcaFocus()
        let roots = [Self.group([["a"]], shown: "a"), Self.group([["c"]], shown: "c")]
        _ = focus.handle(for: 1, in: try Self.listing(roots, inputs: ["a": 1]))
        #expect(focus.handle(for: 1, in: try Self.listing(roots, inputs: ["a": 2])) == "a")
        #expect(focus.handle(for: 2, in: try Self.listing(roots, inputs: ["a": 2, "c": 3])) == "c")
        #expect(focus.handle(for: 1, in: try Self.listing(roots, inputs: ["a": 2, "c": 3])) == "a")
    }

    @Test func inputToAHiddenTabDoesNotMoveTheField() throws {
        var focus = OrcaFocus()
        let roots = [Self.group([["a"], ["b"]], shown: "a"), Self.group([["c"]], shown: "c")]
        _ = focus.handle(for: 1, in: try Self.listing(roots, inputs: ["c": 1]))
        _ = focus.handle(for: 1, in: try Self.listing(roots, inputs: ["c": 2]))
        #expect(focus.handle(for: 1, in: try Self.listing(roots, inputs: ["c": 2, "b": 3])) == "c")
    }

    @Test func forgetsAClosedTerminal() throws {
        var focus = OrcaFocus()
        let roots = [Self.group([["a"]], shown: "a"), Self.group([["c"]], shown: "c")]
        _ = focus.handle(for: 1, in: try Self.listing(roots, inputs: ["a": 1]))
        _ = focus.handle(for: 1, in: try Self.listing(roots, inputs: ["a": 2]))
        let closed = try Self.listing([Self.group([["c"]], shown: "c")])
        #expect(focus.handle(for: 1, in: closed) == "c")
    }
}
