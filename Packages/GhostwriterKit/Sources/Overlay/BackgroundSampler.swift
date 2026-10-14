import AppKit
import GWCore
import ScreenCaptureKit
import os

@MainActor
public enum BackgroundSampling {
    public static var isAllowed: () -> Bool = { false }
}

/// Reads the colour behind a field's caret line from a capture of the field's window only, never of the display,
/// so other apps' windows, notifications and Ghostwriter's own suggestion never show in it. A mid-line suggestion
/// fills that colour over the rest of the line and redraws that text after the suggestion. Needs Screen Recording
/// and the screenshots setting.
@MainActor
final class BackgroundSampler {
    private static let log = Logger.gw("BackgroundSampler")
    private static let lifetime: Duration = .seconds(60)
    private static let maxEntries = 64

    var onSample: ((FieldID) -> Void)?

    private struct Key: Hashable {
        let field: FieldID
        /// The caret line's top edge: lines can differ, e.g. an editor's current-line highlight.
        let line: Int
    }

    private var colors: [Key: (color: RGBAColor, sampledAt: ContinuousClock.Instant)] = [:]
    private var inFlight: Set<Key> = []
    private var pausedUntil: ContinuousClock.Instant?

    /// An old sample is still returned while it refreshes: it is closer than the fallback.
    func color(for snapshot: FieldSnapshot) -> RGBAColor? {
        if let exact = colors[Self.key(snapshot)] { return exact.color }
        return colors.filter { $0.key.field == snapshot.id }.max { $0.value.sampledAt < $1.value.sampledAt }?.value.color
    }

    /// Needs text before the caret: in an empty field the caret line is only estimated and can miss the field.
    /// `delay` lets a window that just opened or moved finish animating before it is captured.
    func sample(_ snapshot: FieldSnapshot, after delay: Duration = .zero) {
        let key = Self.key(snapshot)
        let now = ContinuousClock.now
        if let entry = colors[key], now - entry.sampledAt < Self.lifetime { return }
        guard !snapshot.textBefore.isEmpty, !inFlight.contains(key), pausedUntil.map({ now >= $0 }) ?? true,
              BackgroundSampling.isAllowed(), CGPreflightScreenCaptureAccess(), let strip = Self.strip(for: snapshot)
        else { return }
        let pid = snapshot.app.pid
        inFlight.insert(key)
        Task {
            defer { inFlight.remove(key) }
            do {
                try await Task.sleep(for: delay)
                let color = try await Self.capture(strip, of: pid)
                if colors.count >= Self.maxEntries { colors.removeAll() }
                colors[key] = (color, .now)
                Self.log.debug("Sampled background \(Int(color.red * 255), privacy: .public),\(Int(color.green * 255), privacy: .public),\(Int(color.blue * 255), privacy: .public) over \(Int(strip.width), privacy: .public)x\(Int(strip.height), privacy: .public) pt")
                onSample?(key.field)
            } catch {
                let pause = Self.pause(after: error)
                pausedUntil = .now + pause
                Self.log.error("Sampling a field background failed, next try in \(pause.components.seconds, privacy: .public) s: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated static func pause(after error: any Error) -> Duration {
        if let error = error as? SCStreamError, error.code == .userDeclined { return .seconds(3600) }
        return .seconds(30)
    }

    private static func key(_ snapshot: FieldSnapshot) -> Key {
        Key(field: snapshot.id, line: Int(snapshot.caretRect.minY.rounded()))
    }

    static func strip(for snapshot: FieldSnapshot) -> CGRect? {
        let caret = snapshot.caretRect
        let field = snapshot.fieldFrame
        guard caret.height > 0 else { return nil }
        let (minX, maxX) = field.width >= 1 ? (field.minX, field.maxX) : (caret.minX - 200, caret.maxX + 200)
        let strip = CGRect(x: minX, y: caret.minY, width: maxX - minX, height: caret.height).integral
        return strip.width >= 4 ? strip : nil
    }

    @concurrent
    private nonisolated static func capture(_ strip: CGRect, of pid: pid_t) async throws -> RGBAColor {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter { $0.owningApplication?.processID == pid }
        guard let index = window(holding: strip, frames: windows.map(\.frame)) else { throw SamplingError.offScreen }
        let window = windows[index]
        let local = strip.intersection(window.frame)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = local.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        configuration.width = max(1, Int((local.width * scale).rounded()))
        configuration.height = max(1, Int((local.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let color = dominantColor(of: image) else { throw SamplingError.unreadable }
        return color
    }

    /// The smallest window around the strip's centre: a sheet or popover holding the field lies inside its
    /// parent window. Nil when the strip is not on one of the windows.
    nonisolated static func window(holding strip: CGRect, frames: [CGRect]) -> Int? {
        let center = CGPoint(x: strip.midX, y: strip.midY)
        return frames.indices
            .filter { frames[$0].contains(center) }
            .min { frames[$0].width * frames[$0].height < frames[$1].width * frames[$1].height }
    }

    /// The most common colour, in sRGB. Text covers a minority of a line's pixels, so this is the background.
    nonisolated static func dominantColor(of image: CGImage) -> RGBAColor? {
        let width = min(image.width, 600)
        let height = min(image.height, 24)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        // Nearest-neighbour scaling keeps real pixel colours instead of blends of text and background.
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytes = UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: width * height * 4), count: width * height * 4)
        return dominantColor(rgba: bytes)
    }

    nonisolated static func dominantColor<Bytes: Collection<UInt8>>(rgba: Bytes) -> RGBAColor? where Bytes.Index == Int {
        var buckets: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        var index = rgba.startIndex
        while index + 3 < rgba.endIndex {
            let red = Int(rgba[index]), green = Int(rgba[index + 1]), blue = Int(rgba[index + 2])
            let key = (red >> 3) << 10 | (green >> 3) << 5 | blue >> 3
            let entry = buckets[key, default: (0, 0, 0, 0)]
            buckets[key] = (entry.count + 1, entry.red + red, entry.green + green, entry.blue + blue)
            index += 4
        }
        guard let top = buckets.values.max(by: { $0.count < $1.count }), top.count > 0 else { return nil }
        let count = Double(top.count) * 255
        return RGBAColor(red: Double(top.red) / count, green: Double(top.green) / count, blue: Double(top.blue) / count)
    }

    private enum SamplingError: Error {
        case offScreen
        case unreadable
    }
}
