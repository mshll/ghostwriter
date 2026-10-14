import Observation
import SwiftUI

@Observable
final class SettingsNavigation {
    var pane: SettingsPane
    var app: String?

    init(pane: SettingsPane) {
        self.pane = pane
    }
}

struct SettingsView: View {
    static let width: CGFloat = 800

    @Bindable var navigation: SettingsNavigation
    @Environment(Preferences.self) private var preferences
    @FocusState private var focusesAbout: Bool?
    /// Lives with the view, not the navigation, so a closed window forgets its search.
    @State private var query = ""
    @State private var columns = NavigationSplitViewVisibility.all

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SettingsSidebar(selection: $navigation.pane, query: trimmedQuery, focusesAbout: $focusesAbout)
                // Equal bounds pin the divider. They only take after the toggle's removal: the
                // other way round, the column ignores its width altogether.
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 215, ideal: 215, max: 215)
        } detail: {
            SettingsDetail(pane: navigation.pane)
                .environment(navigation)
                .environment(\.settingsMatches, trimmedQuery.isEmpty ? [] : navigation.pane.matches(trimmedQuery))
        }
        // Without an ideal height the window first lays out at the form's full height, and its
        // scroll view keeps the bottom in view when the window shrinks to size.
        .frame(width: Self.width)
        .frame(minHeight: 480, idealHeight: 640)
        .searchable(text: $query, placement: .sidebar)
        .onSubmit(of: .search) { focusesAbout = navigation.pane == .about }
        // The divider can still be dragged past its minimum to collapse the sidebar, and with no
        // toggle there would be no way to bring it back, so it is put straight back.
        .onChange(of: columns) { _, visibility in
            if visibility != .all { columns = .all }
        }
        .onChange(of: navigation.pane) { _, pane in
            let searching = !trimmedQuery.isEmpty
            if searching, !pane.isFound(by: trimmedQuery) { query = "" }
            guard !searching, pane != .about else { return }
            preferences.settingsPane = pane
        }
        .onChange(of: trimmedQuery) { _, query in
            guard !query.isEmpty, !navigation.pane.isFound(by: query),
                  let first = SettingsPane.allCases.first(where: { $0.isFound(by: query) })
            else { return }
            navigation.pane = first
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsPane
    let query: String
    var focusesAbout: FocusState<Bool?>.Binding

    private var groups: [[SettingsPane]] {
        guard !query.isEmpty else { return SettingsPane.groups }
        return SettingsPane.groups
            .map { $0.filter { $0.isFound(by: query) } }
            .filter { !$0.isEmpty }
    }

    private var showsAbout: Bool { query.isEmpty || SettingsPane.about.isFound(by: query) }

    var body: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.first) { group in
                Section {
                    ForEach(group, content: row)
                }
            }
        }
        .focused(focusesAbout, equals: false)
        // A second list on the same selection, so About keeps the sidebar's highlight and insets.
        // A bar, not an inset, so rows scrolling under it get the search field's edge effect.
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if showsAbout {
                List(selection: $selection) {
                    row(.about)
                }
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                .frame(height: 44)
                .focused(focusesAbout, equals: true)
            }
        }
        // A list without the keyboard draws its selection greyed, so the keyboard follows the
        // selection between the two. Not during a search: the field keeps the keys.
        .onChange(of: selection, initial: true) { _, pane in
            if query.isEmpty { focusesAbout.wrappedValue = pane == .about }
        }
        .overlay {
            if groups.isEmpty, !showsAbout {
                Text("No Results")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ pane: SettingsPane) -> some View {
        Label {
            // The sidebar bolds the selected row on its own; pin the weight.
            Text(pane.title)
                .fontWeight(.regular)
        } icon: {
            SettingsPaneIcon(pane: pane, size: 20)
        }
        .tag(pane)
    }
}

private struct SettingsDetail: View {
    let pane: SettingsPane

    var body: some View {
        switch pane {
        case .general: GeneralPane()
        case .suggestions: SuggestionsPane()
        case .shortcuts: ShortcutsPane()
        case .model: ModelPane()
        case .context: ContextPane()
        case .personalization: PersonalizationPane()
        case .apps: AppsPane()
        case .snippets: SnippetsPane()
        case .selectionActions: SelectionActionsPane()
        case .statistics: StatisticsPane()
        case .privacy: PrivacyPane()
        case .updates: UpdatesPane()
        case .about: AboutPane()
        }
    }
}
