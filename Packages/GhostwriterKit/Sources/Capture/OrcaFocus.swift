/// Picks the Orca terminal the user types in. Orca's `terminal.resolveActive` returns the active pane of the first tab
/// it knows, not the focused one. Orca lists the active tab of every tab group and when each terminal last got input,
/// but not which workspace is on screen, so the input field that typing went to is remembered.
struct OrcaFocus {
    struct Listing: Decodable {
        struct Listed: Decodable {
            struct Attention: Decodable {
                var lastInputAt: Double?
            }

            var handle: String
            var attention: Attention?
        }

        var terminals: [Listed]
        var visualLayouts: [Layout]?
    }

    struct Layout: Decodable {
        var root: Node
    }

    /// A tab group, a split of groups, a tab's terminal pane or a split of panes, told apart by which fields are set.
    final class Node: Decodable {
        struct Tab: Decodable {
            var tabId: String
            var panes: Node
        }

        let first: Node?
        let second: Node?
        let activeTabId: String?
        let tabs: [Tab]?
        let handle: String?
        let active: Bool?
    }

    struct Group: Equatable {
        var handles: Set<String>
        var shown: String?
    }

    private var handleByField: [UInt: String] = [:]
    private var lastInputAt: Double?

    mutating func handle(for field: UInt, in listing: Listing) -> String? {
        let groups = listing.groups
        let typed = listing.lastTyped
        let live = Set(listing.terminals.map(\.handle))
        handleByField = handleByField.filter { live.contains($0.value) }
        // Input to a terminal hidden behind another tab comes from an agent, not from the keyboard.
        if let typed, let lastInputAt, typed.at > lastInputAt,
           groups.allSatisfy({ !$0.handles.contains(typed.handle) || $0.shown == typed.handle }) {
            handleByField[field] = typed.handle
        }
        lastInputAt = typed?.at ?? lastInputAt
        if let known = handleByField[field] { return known }
        guard let typed else { return groups.count == 1 ? groups[0].shown : nil }
        return groups.first { $0.handles.contains(typed.handle) }?.shown ?? typed.handle
    }
}

extension OrcaFocus.Listing {
    var groups: [OrcaFocus.Group] { (visualLayouts ?? []).flatMap(\.root.groups) }

    var lastTyped: (handle: String, at: Double)? {
        terminals
            .compactMap { terminal in terminal.attention?.lastInputAt.map { (handle: terminal.handle, at: $0) } }
            .max { $0.at < $1.at }
    }
}

extension OrcaFocus.Node {
    var groups: [OrcaFocus.Group] {
        guard let tabs else { return (first?.groups ?? []) + (second?.groups ?? []) }
        let shown = tabs.first { $0.tabId == activeTabId }?.panes.activeHandle
        return [OrcaFocus.Group(handles: Set(tabs.flatMap(\.panes.handles)), shown: shown)]
    }

    var handles: [String] { handle.map { [$0] } ?? (first?.handles ?? []) + (second?.handles ?? []) }

    var activeHandle: String? { active == true ? handle : first?.activeHandle ?? second?.activeHandle }
}
