import Actions
import SwiftUI

enum SelectionActionsPlacement {
    case below, above
}

struct SelectionActionsView: View {
    static let contentInsets = EdgeInsets(top: 16, leading: 48, bottom: 16, trailing: 48)
    static let canvasSize = CGSize(width: cardWidth + contentInsets.leading + contentInsets.trailing, height: 440)
    private static let cardWidth: CGFloat = 440

    let model: SelectionActionsModel
    let placement: SelectionActionsPlacement
    let replace: (String) -> Void
    let copy: (String) -> Void
    let close: () -> Void

    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if placement == .above { resultCard }
                SelectionToolbar(model: model, labelEdge: placement == .below ? .bottom : .top, close: close)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("toolbar", in: glass)
                    .zIndex(1)
                if placement == .below { resultCard }
            }
        }
        .padding(Self.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placement == .below ? .topLeading : .bottomLeading)
        .animation(.smooth(duration: 0.3), value: model.phase == .choosing)
    }

    @ViewBuilder private var resultCard: some View {
        if model.phase != .choosing {
            ResultCard(model: model, replace: replace, copy: copy)
                .frame(width: Self.cardWidth, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .glassEffectID("result", in: glass)
        }
    }
}

private struct SelectionToolbar: View {
    let model: SelectionActionsModel
    let labelEdge: VerticalEdge
    let close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if let reason = model.unavailableReason {
                Label(reason, systemImage: "apple.intelligence")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360, alignment: .leading)
                    .padding(.leading, 10)
            } else {
                ForEach(Array(model.actions.enumerated()), id: \.element) { index, action in
                    let number = index + 1
                    ToolbarButton(
                        title: action == .translate ? "Translate to \(model.targetLanguage)" : action.title,
                        symbol: action.symbol,
                        isActive: (model.phase.action ?? model.failedAction) == action,
                        labelEdge: labelEdge,
                        shortcut: String(number).first.map { KeyboardShortcut(KeyEquivalent($0), modifiers: []) }
                    ) {
                        model.run(action)
                    }
                }
                if model.offersSynonyms {
                    ToolbarButton(
                        title: "Synonyms", symbol: "character.book.closed", isActive: model.phase.isSynonyms, labelEdge: labelEdge
                    ) {
                        model.loadSynonyms()
                    }
                }
            }
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 3)
            ToolbarButton(title: "Close", symbol: "xmark", labelEdge: labelEdge, shortcut: .cancelAction, action: close)
        }
        .padding(3)
    }
}

private struct ToolbarButton: View {
    let title: String
    let symbol: String
    var isActive = false
    let labelEdge: VerticalEdge
    var shortcut: KeyboardShortcut?
    let action: () -> Void

    private static let labelOffset = ToolbarButtonStyle.size + 10

    @State private var isHovered = false

    var body: some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(ToolbarButtonStyle(isActive: isActive, isHovered: isHovered))
            .keyboardShortcut(shortcut)
            .onHover { isHovered = $0 }
            .overlay(alignment: labelEdge == .bottom ? .top : .bottom) {
                if isHovered {
                    HoverLabel(title: title, key: keyName)
                        .offset(y: labelEdge == .bottom ? Self.labelOffset : -Self.labelOffset)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var keyName: String? {
        switch shortcut {
        case .some(.cancelAction): "Esc"
        case .some(let shortcut): String(shortcut.key.character)
        case nil: nil
        }
    }
}

private struct HoverLabel: View {
    let title: String
    let key: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let key {
                Text(key).foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
        .fixedSize()
        .allowsHitTesting(false)
    }
}

private struct ToolbarButtonStyle: ButtonStyle {
    static let size: CGFloat = 28

    let isActive: Bool
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .frame(width: Self.size, height: Self.size)
            .background(Circle().fill(Color.primary.opacity(fillOpacity(isPressed: configuration.isPressed))))
            .contentShape(Circle())
    }

    private func fillOpacity(isPressed: Bool) -> Double {
        if isPressed { 0.16 } else if isActive || isHovered { 0.08 } else { 0 }
    }
}

private struct ResultCard: View {
    let model: SelectionActionsModel
    let replace: (String) -> Void
    let copy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ResultHeader(model: model)
            SelectionResultView(model: model, replace: replace)
            SelectionFooter(model: model, replace: replace, copy: copy)
        }
        .padding(14)
    }
}

private struct ResultHeader: View {
    @Bindable var model: SelectionActionsModel

    var body: some View {
        HStack(spacing: 6) {
            switch model.phase {
            case .running(.translate, _), .finished(.translate, _):
                TranslatePicker(model: model)
            case .failed where model.failedAction == .translate:
                TranslatePicker(model: model)
            case .running(let action, _), .finished(let action, _):
                Label(action.title, systemImage: action.symbol)
            case .synonyms:
                Label("Synonyms for \u{201C}\(model.selectedText)\u{201D}", systemImage: "character.book.closed")
                    .lineLimit(1)
            case .failed:
                Label("Something went wrong", systemImage: "exclamationmark.triangle")
            case .choosing:
                EmptyView()
            }
            Spacer(minLength: 0)
            if model.phase.isWorking {
                ProgressView().controlSize(.small)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .controlSize(.small)
    }
}

private struct TranslatePicker: View {
    @Bindable var model: SelectionActionsModel

    var body: some View {
        Picker("Translate to", selection: $model.targetLanguage) {
            ForEach(WritingAction.translationLanguages, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .onChange(of: model.targetLanguage) { model.run(.translate) }
    }
}

private struct SelectionResultView: View {
    @Bindable var model: SelectionActionsModel
    let replace: (String) -> Void

    var body: some View {
        switch model.phase {
        case .choosing:
            EmptyView()
        case .running(_, let text), .finished(_, let text):
            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 20, maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
        case .synonyms(let loading, let items):
            if loading {
                Text("Finding synonyms\u{2026}")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            } else if items.isEmpty {
                Text("No synonyms found.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            } else {
                SynonymChips(items: items, selection: $model.selectedSynonym, choose: replace)
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SynonymChips: View {
    let items: [String]
    @Binding var selection: String?
    let choose: (String) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                SynonymChip(title: item, isSelected: item == selection) { choose(item) }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(keys: [.leftArrow, .upArrow]) { _ in moveSelection(by: -1) }
        .onKeyPress(keys: [.rightArrow, .downArrow]) { _ in moveSelection(by: 1) }
        .onAppear { isFocused = true }
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        let index = selection.flatMap(items.firstIndex(of:)) ?? 0
        selection = items[min(max(index + offset, 0), items.count - 1)]
        return .handled
    }
}

private struct SynonymChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(SynonymChipStyle(isSelected: isSelected, isHovered: isHovered))
            .onHover { isHovered = $0 }
    }
}

private struct SynonymChipStyle: ButtonStyle {
    let isSelected: Bool
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill(isPressed: configuration.isPressed)))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fill(isPressed: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(isPressed ? 0.3 : 0.18) }
        return Color.primary.opacity(isPressed ? 0.16 : isHovered ? 0.1 : 0.05)
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let bounds = frames(in: proposal.width ?? .infinity, subviews: subviews).reduce(CGRect.null) { $0.union($1) }
        return bounds.isNull ? .zero : CGSize(width: proposal.width ?? bounds.maxX, height: bounds.maxY)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(in: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(in width: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + rowHeight + spacing)
                rowHeight = 0
            }
            frames.append(CGRect(origin: origin, size: size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}

private struct SelectionFooter: View {
    let model: SelectionActionsModel
    let replace: (String) -> Void
    let copy: (String) -> Void

    var body: some View {
        HStack {
            Button("Try Again", systemImage: "arrow.clockwise", action: model.retry)
                .labelStyle(.iconOnly)
                .keyboardShortcut("r", modifiers: .command)
                .help("Try Again (\u{2318}R)")
                .disabled(!model.canRetry)
            Spacer()
            Button("Copy") {
                if let text = model.replacement { copy(text) }
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(model.replacement == nil)
            Button("Replace") {
                if let text = model.replacement { replace(text) }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(model.replacement == nil)
        }
    }
}

private extension SelectionActionsModel.Phase {
    var action: WritingAction? {
        switch self {
        case .running(let action, _), .finished(let action, _): action
        case .choosing, .synonyms, .failed: nil
        }
    }

    var isSynonyms: Bool {
        if case .synonyms = self { true } else { false }
    }

    var isWorking: Bool {
        switch self {
        case .running, .synonyms(loading: true, _): true
        case .choosing, .finished, .synonyms, .failed: false
        }
    }
}
