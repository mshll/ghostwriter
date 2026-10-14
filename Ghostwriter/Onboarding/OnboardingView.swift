import Inference
import SwiftUI

struct OnboardingView: View {
    let model: OnboardingModel

    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                if !model.isLeaving {
                    VStack(spacing: 40) {
                        VStack(spacing: 22) {
                            Headline(model: model)
                            if model.step.acceptsWithKeys {
                                KeyHint(model: model)
                            }
                        }
                        StepContent(model: model)
                            .id(model.step)
                            .transition(.rise(delay: 0.3))
                    }
                    .padding(.top, proxy.size.height * 0.2)
                    .transition(.opacity.animation(.easeIn(duration: 0.25)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .overlay(alignment: .top) {
                if !model.isLeaving {
                    TopBar(model: model)
                }
            }
            .overlay {
                if model.isLeaving, let target = model.statusItemFrame {
                    ExitCaret(target: target, size: proxy.size)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(OnboardingStyle.accent)
        .pollsPermissions(appState, confirmingCaptureFor: preferences)
        .onChange(of: appState.accessibilityGranted) { model.accessibilityChanged() }
    }
}

private struct Headline: View {
    let model: OnboardingModel

    var body: some View {
        let words = [model.step.ink] + model.ghostWords
        HStack(spacing: 0) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(index == 0 ? word : " " + word)
                    .foregroundStyle(index <= model.acceptedWords ? OnboardingStyle.ink : OnboardingStyle.ghost)
                    .overlay(alignment: .trailing) {
                        if index == model.acceptedWords, !model.headlineComplete {
                            Caret().offset(x: 7)
                        }
                    }
            }
        }
        .font(.system(size: 64, weight: .medium))
        .tracking(-1.9)
        .lineLimit(1)
        .fixedSize()
        .id(model.step)
        .transition(.rise())
    }
}

private struct Caret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.55)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / 0.55).isMultiple(of: 2)
            Capsule()
                .fill(OnboardingStyle.accent)
                .frame(width: 4, height: 56)
                .opacity(on ? 1 : 0)
        }
    }
}

private struct KeyHint: View {
    let model: OnboardingModel
    @Environment(Preferences.self) private var preferences

    var body: some View {
        let word = preferences.acceptWordKey.displayName
        let all = preferences.acceptFullKey.displayName
        HStack(spacing: 8) {
            if model.headlineComplete {
                OnboardingKeycap(label: "Return")
                Text(model.step == .done ? "to start writing" : "to continue")
            } else {
                Text("Press")
                OnboardingKeycap(label: word, pressed: model.pressedKey == word)
                Text("to take a word,")
                OnboardingKeycap(label: all, pressed: model.pressedKey == all)
                Text("for all of it")
            }
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(OnboardingStyle.muted)
        .animation(.easeOut(duration: 0.2), value: model.headlineComplete)
    }
}

private struct TopBar: View {
    let model: OnboardingModel
    @Environment(ModelLibrary.self) private var library

    var body: some View {
        ZStack {
            if model.step != .model, let spec = library.downloadingModels.first,
               let progress = library.downloadProgress[spec.id] {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                    Text("Downloading \(spec.displayName)")
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(OnboardingStyle.muted)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OnboardingStyle.ink)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color(white: 0.12, opacity: 0.9), in: .capsule)
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                .transition(.opacity)
            }
            if model.step != .practice {
                Button(action: model.finish) {
                    HStack(spacing: 8) {
                        Text(model.skipArmed ? "Press esc again to skip" : "Skip setup")
                            .contentTransition(.opacity)
                        OnboardingKeycap(label: "esc", pressed: model.skipArmed)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(model.skipArmed ? OnboardingStyle.ink : OnboardingStyle.muted)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
    }
}

private struct ExitCaret: View {
    let target: CGRect
    let size: CGSize
    @State private var phase = 0
    @State private var ringGrows = false

    var body: some View {
        ZStack {
            Capsule()
                .fill(OnboardingStyle.accent)
                .frame(width: phase >= 2 ? 3 : 6, height: phase >= 2 ? 14 : (phase >= 1 ? size.height * 0.4 : 0))
                .position(phase >= 2 ? CGPoint(x: target.midX, y: target.midY) : CGPoint(x: size.width / 2, y: size.height * 0.42))
                .opacity(phase >= 3 ? 0 : 1)
            Circle()
                .stroke(OnboardingStyle.accent, lineWidth: 2)
                .frame(width: 24, height: 24)
                .scaleEffect(ringGrows ? 2.4 : 1)
                .opacity(phase >= 3 && !ringGrows ? 1 : 0)
                .position(x: target.midX, y: target.midY)
        }
        .task {
            withAnimation(.easeOut(duration: 0.35)) { phase = 1 }
            do {
                try await Task.sleep(for: .milliseconds(450))
                withAnimation(.spring(duration: 0.6, bounce: 0.12)) { phase = 2 }
                try await Task.sleep(for: .milliseconds(650))
                withAnimation(.easeOut(duration: 0.15)) { phase = 3 }
                for _ in 0..<2 {
                    ringGrows = false
                    withAnimation(.easeOut(duration: 0.7)) { ringGrows = true }
                    try await Task.sleep(for: .milliseconds(750))
                }
            } catch {
                return
            }
        }
    }
}

private struct StepContent: View {
    let model: OnboardingModel

    var body: some View {
        switch model.step {
        case .welcome: EmptyView()
        case .access: AccessStep(model: model)
        case .model: ModelStep(model: model)
        case .personal: PersonalStep(model: model)
        case .context: ContextStep(model: model)
        case .practice: PracticeStep(model: model)
        case .done: DoneStep()
        }
    }
}
