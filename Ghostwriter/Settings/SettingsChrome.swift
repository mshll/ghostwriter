import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var settingsMatches: [String] = []
    @Entry var replayOnboarding: @MainActor () -> Void = {}
}

struct SettingText {
    let title: String
    let subtitle: String?
    let keywords: [String]

    init(_ title: String, subtitle: String? = nil, keywords: [String] = []) {
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
    }
}

/// A pane's searchable rows, in the order the pane draws them: search scrolls to the first match.
protocol SettingKey: CaseIterable {
    var text: SettingText { get }
}

/// The control's label is hidden, not dropped: give it the row's title so VoiceOver reads one.
struct SettingRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let control: Control

    var body: some View {
        LabeledContent {
            control
                .labelsHidden()
        } label: {
            Text(title)
            if let subtitle {
                Text(subtitle)
            }
        }
        .settingsSearchTarget(title)
    }
}

extension SettingRow {
    init(_ key: some SettingKey, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.init(title: key.text.title, subtitle: subtitle ?? key.text.subtitle, control: control)
    }
}

extension SettingRow where Control == Toggle<Text> {
    init(_ key: some SettingKey, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.init(key, subtitle: subtitle) { Toggle(key.text.title, isOn: isOn) }
    }
}

extension View {
    func settingsSearchTarget(_ key: some SettingKey) -> some View {
        settingsSearchTarget(key.text.title)
    }

    func settingsSearchTarget(_ title: String) -> some View {
        modifier(SettingsSearchTarget(title: title))
    }
}

extension PermissionStatusRow {
    init(_ key: some SettingKey, isGranted: Bool, request: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.init(title: key.text.title, subtitle: key.text.subtitle, isGranted: isGranted, request: request, openSettings: openSettings)
    }
}

private struct SettingsSearchTarget: ViewModifier {
    let title: String
    @Environment(\.settingsMatches) private var matches

    func body(content: Content) -> some View {
        content
            .background {
                if matches.contains(title) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .padding(.horizontal, -8)
                        .padding(.vertical, -5)
                }
            }
            .id(title)
    }
}

struct SettingsPaneView<Content: View>: View {
    let pane: SettingsPane
    @ViewBuilder let content: Content

    private var isCompact: Bool { pane != .about }

    var body: some View {
        SettingsPage(title: pane.headerTitle, summary: pane.summary, isCompact: isCompact) {
            SettingsPaneIcon(pane: pane, size: isCompact ? SettingsPaneIcon.compactSize : 56)
        } content: {
            content
        }
    }
}

struct SettingsPage<Icon: View, Content: View>: View {
    let title: String
    let summary: String
    var isCompact = true
    @ViewBuilder let icon: Icon
    @ViewBuilder let content: Content

    @Environment(\.settingsMatches) private var matches
    @State private var showsHeader = true

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    header
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        .onScrollVisibilityChange { showsHeader = $0 }
                }

                content
            }
            .formStyle(.grouped)
            // Rows that fill in after the page appears would otherwise push the first view down the page.
            .defaultScrollAnchor(.top)
            .toggleStyle(.switch)
            .navigationTitle(title)
            .toolbar(removing: showsHeader ? .title : nil)
            .onChange(of: matches.first, initial: true) { _, first in
                guard let first else { return }
                withAnimation { proxy.scrollTo(first, anchor: .center) }
            }
        }
    }

    @ViewBuilder private var header: some View {
        if isCompact {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title3.bold())
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        } else {
            VStack(spacing: 0) {
                icon
                    .padding(.bottom, 12)
                Text(title)
                    .font(.title.bold())
                    .padding(.bottom, 6)
                Text(summary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
    }
}

struct SettingsPaneIcon: View {
    static let compactSize: CGFloat = 40

    let pane: SettingsPane
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let symbol = pane.symbol {
            let tile = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            tile
                .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                .overlay {
                    if colorScheme == .dark {
                        tile.strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                    }
                }
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.44, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            AppIconTile(image: NSApp.applicationIconImage, size: size)
        }
    }
}

/// A macOS icon leaves a margin around its shape inside the canvas. Drawn a quarter larger than the
/// frame, its shape lines up with the tiles around it.
struct AppIconTile: View {
    let image: NSImage
    let size: CGFloat

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .frame(width: size * 1.25, height: size * 1.25)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct LinkRow: View {
    let title: String
    let url: URL

    init(_ key: some SettingKey, url: URL) {
        title = key.text.title
        self.url = url
    }

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(url)
        } label: {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .settingsSearchTarget(title)
    }
}

extension View {
    /// A page pushed inside the detail column gets no back button of its own, since the split view owns the toolbar.
    func settingsBackButton(discardWarning: String? = nil) -> some View {
        modifier(SettingsBackButton(discardWarning: discardWarning))
    }
}

private struct SettingsBackButton: ViewModifier {
    let discardWarning: String?
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirming = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("Back", systemImage: "chevron.backward") {
                        if discardWarning == nil { dismiss() } else { isConfirming = true }
                    }
                }
            }
            .confirmationDialog("Discard this change?", isPresented: $isConfirming) {
                Button("Discard", role: .destructive) { dismiss() }
            } message: {
                Text(discardWarning ?? "")
            }
    }
}
