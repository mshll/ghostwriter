import AppKit
import SwiftUI

enum OnboardingStyle {
    static let inkColor = NSColor(srgbRed: 0.925, green: 0.925, blue: 0.918, alpha: 0.92)
    static let ghostColor = NSColor(white: 1, alpha: 0.3)
    static let page = Color(red: 0.043, green: 0.043, blue: 0.047)
    static let ink = Color(red: 0.925, green: 0.925, blue: 0.918)
    static let inkSoft = Color(red: 0.706, green: 0.706, blue: 0.69)
    static let muted = Color(red: 0.553, green: 0.553, blue: 0.537)
    static let ghost = Color.white.opacity(0.4)
    static let accent = Color(red: 0.039, green: 0.518, blue: 1)
    static let easeOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.9)
}

struct OnboardingPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .frame(width: 580)
            .background {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(OnboardingStyle.ink.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0)], startPoint: .top, endPoint: .center))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .strokeBorder(LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.28), location: 0),
                                    .init(color: .white.opacity(0.06), location: 0.3),
                                    .init(color: .white.opacity(0.02), location: 0.62),
                                    .init(color: .white.opacity(0.14), location: 1),
                                ],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 18, y: 16)
            }
    }
}

struct OnboardingRow<Accessory: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OnboardingStyle.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(OnboardingStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(.vertical, 14)
    }
}

struct OnboardingDivider: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
    }
}

struct OnboardingButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .medium))
            .tracking(-0.17)
            .foregroundStyle(prominent ? OnboardingStyle.page : OnboardingStyle.ink)
            .padding(.horizontal, 22)
            .frame(height: 44)
            .background(prominent ? OnboardingStyle.ink : Color(white: 0.122), in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
            .contentShape(.capsule)
    }
}

struct OnboardingKeycap: View {
    let label: String
    var pressed = false

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(OnboardingStyle.ink)
            .padding(.horizontal, 7)
            .frame(minWidth: 26, minHeight: 26)
            .background(
                LinearGradient(colors: pressed ? [Color(white: 0.24), Color(white: 0.19)] : [Color(white: 0.173), Color(white: 0.125)],
                               startPoint: .top, endPoint: .bottom),
                in: .rect(cornerRadius: 7)
            )
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black, radius: 0, y: pressed ? 0 : 2)
            .shadow(color: .black.opacity(0.45), radius: 4, y: 3)
            .offset(y: pressed ? 2 : 0)
            .animation(.easeOut(duration: 0.11), value: pressed)
    }
}

private struct Rise: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .offset(y: hidden ? 18 : 0)
            .blur(radius: hidden ? 8 : 0)
    }
}

extension AnyTransition {
    static func rise(delay: Double = 0) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Rise(hidden: true), identity: Rise(hidden: false))
                .animation(OnboardingStyle.easeOut.delay(delay)),
            removal: .opacity.animation(.easeIn(duration: 0.18))
        )
    }
}
