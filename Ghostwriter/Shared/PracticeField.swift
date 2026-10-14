import SwiftUI

struct PracticeField: View {
    static let identifier = "GhostwriterPracticeField"

    @Binding var text: String
    let placeholder: String
    var font: Font = .body
    var padding: CGFloat = 8

    @Environment(AppState.self) private var appState

    var body: some View {
        TextEditor(text: $text)
            .font(font)
            .scrollContentBackground(.hidden)
            .padding(padding)
            .background(.background, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(font)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, padding + 5)
                        .padding(.vertical, padding)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityIdentifier(Self.identifier)
            .onAppear { appState.practiceFieldVisible = true }
            .onDisappear { appState.practiceFieldVisible = false }
    }

}
