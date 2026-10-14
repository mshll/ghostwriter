import CoreGraphics
import CoreText
import Foundation
import GWCore
import ScreenCaptureKit
import Vision

enum WindowOCRError: Error {
    case windowNotFound
    case imageProcessing
}

enum WindowOCR {
    static let maxLongEdge: CGFloat = 2000
    static let minimumConfidence: Float = 0.3
    static let bandAbove: CGFloat = 600
    static let bandBelow: CGFloat = 200

    static func captureOwnWindowSample() async throws -> Bool {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == getpid() && $0.windowLayer == 0 && $0.frame.width >= 8
                && $0.frame.height >= 8
        }) else { return false }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: 0, y: 0, width: 4, height: 4)
        configuration.width = 4
        configuration.height = 4
        configuration.showsCursor = false
        _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return true
    }

    static func isDeclined(_ error: any Error) -> Bool {
        (error as? SCStreamError)?.code == .userDeclined
    }

    /// Only that window is captured, never a screen region, which would include other apps and notifications.
    static func recognize(
        pid: pid_t, windowFrame: CGRect, mask: CGRect, caret: CGRect, languages: [Locale.Language]?
    ) async throws -> [TextChunk] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
        guard let index = matchingWindow(candidates.map(\.frame), windowFrame: windowFrame, mask: mask)
        else { throw WindowOCRError.windowNotFound }
        let window = candidates[index]

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let frame = window.frame
        let region = captureRegion(window: frame, caret: caret)
        let scale = min(CGFloat(filter.pointPixelScale), maxLongEdge / max(region.width, region.height, 1))
        let configuration = SCStreamConfiguration()
        if region != frame {
            configuration.sourceRect = region.offsetBy(dx: -frame.minX, dy: -frame.minY)
        }
        configuration.width = Int((region.width * scale).rounded())
        configuration.height = Int((region.height * scale).rounded())
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return try await recognize(image: image, imageFrame: region, mask: mask, languages: languages)
    }

    static func captureRegion(window: CGRect, caret: CGRect) -> CGRect {
        let band = CGRect(
            x: window.minX, y: caret.minY - bandAbove, width: window.width, height: bandAbove + caret.height + bandBelow
        ).intersection(window)
        guard !band.isNull, !band.isEmpty, band.height <= window.height * 0.75 else { return window }
        return band
    }

    static func recognize(
        image: CGImage, imageFrame: CGRect, mask: CGRect, languages: [Locale.Language]?
    ) async throws -> [TextChunk] {
        let masked = try masking(image, imageFrame: imageFrame, mask: mask)
        let observations = try await textRequest(languages: languages).perform(on: masked)
        let lines = observations.compactMap { observation -> TextChunk? in
            guard observation.confidence >= minimumConfidence,
                  let text = observation.topCandidates(1).first?.string
            else { return nil }
            let box = observation.boundingBox.cgRect
            let frame = CGRect(
                x: imageFrame.minX + box.minX * imageFrame.width,
                y: imageFrame.minY + (1 - box.maxY) * imageFrame.height,
                width: box.width * imageFrame.width,
                height: box.height * imageFrame.height
            )
            return TextChunk(text: text, frame: frame)
        }
        return paragraphs(from: lines)
    }

    /// Loads the recognition models for one language configuration; after a new build this first compiles them,
    /// which takes one to two and a half minutes. Reads a window-sized sample: a one-line sample left about half
    /// of the compile to the first real window.
    static func prewarm(languages: [Locale.Language]?) async throws {
        _ = try await textRequest(languages: languages).perform(on: try sampleWindow())
    }

    static let supportedLanguages: [Locale.Language] = {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        return request.supportedRecognitionLanguages
    }()

    /// The field's language and English, or nil to let Vision detect languages: a fixed list silently drops
    /// text in other scripts, so it is used only when the field's language is known and supported.
    static func recognitionLanguages(
        for language: String?, supported: [Locale.Language] = supportedLanguages
    ) -> [Locale.Language]? {
        guard let language else { return nil }
        let wanted = Locale.Language(identifier: language)
        let sameLanguage = supported.filter { $0.languageCode == wanted.languageCode }
        let script = Locale.Language(identifier: wanted.maximalIdentifier).script
        guard let match = sameLanguage.first(where: {
            Locale.Language(identifier: $0.maximalIdentifier).script == script
        }) else { return nil }
        guard match.languageCode != .english,
              let english = supported.first(where: { $0.languageCode == .english }) else { return [match] }
        return [match, english]
    }

    private static func textRequest(languages: [Locale.Language]?) -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let languages {
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = languages
        } else {
            request.automaticallyDetectsLanguage = true
        }
        return request
    }

    private static func sampleWindow() throws -> CGImage {
        let width = 2000, height = 1300
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw WindowOCRError.imageProcessing }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let lines = [
            "Sample heading for the warm-up page", "The quick brown fox jumps over the lazy dog near the river bank.",
            "Meeting notes: review the draft on Tuesday at 10:30 and send comments by Friday.",
            "Order 4821 shipped on 12 March; the parcel should arrive within three working days.",
        ]
        var y = CGFloat(height) - 80
        for index in 0..<26 {
            let size: CGFloat = index % 9 == 0 ? 34 : 26
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let text = NSAttributedString(string: lines[index % lines.count], attributes: [.font: font])
            context.textPosition = CGPoint(x: 48, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            y -= size * 1.8
        }
        guard let image = context.makeImage() else { throw WindowOCRError.imageProcessing }
        return image
    }

    static func paragraphs(from lines: [TextChunk]) -> [TextChunk] {
        var blocks: [(text: String, frame: CGRect, last: CGRect)] = []
        for line in lines.sorted(by: { $0.frame.minY < $1.frame.minY }) {
            let index = blocks.lastIndex { block in
                let gap = line.frame.minY - block.last.maxY
                let height = max(line.frame.height, block.last.height)
                return abs(line.frame.minX - block.last.minX) <= height
                    && gap >= -height / 2 && gap <= height * 0.9
            }
            guard let index else {
                blocks.append((line.text, line.frame, line.frame))
                continue
            }
            let previous = blocks[index].last
            let previousIsLong = previous.width >= previous.height * 15 && previous.width >= line.frame.width
            let previousEndsSentence = blocks[index].text.last.map { ".!?:;".contains($0) } ?? true
            let wraps = (line.text.first?.isLowercase ?? false) || (previousIsLong && !previousEndsSentence)
            blocks[index].text = wraps
                ? ScreenText.join(blocks[index].text, line.text, newLine: false)
                : blocks[index].text + "\n" + line.text
            blocks[index].frame = blocks[index].frame.union(line.frame)
            blocks[index].last = line.frame
        }
        return blocks.map { TextChunk(text: $0.text, frame: $0.frame) }
    }

    private static func masking(_ image: CGImage, imageFrame: CGRect, mask: CGRect) throws -> CGImage {
        let target = mask.intersection(imageFrame)
        guard !target.isNull, !target.isEmpty else { return image }
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw WindowOCRError.imageProcessing }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        let sx = CGFloat(image.width) / imageFrame.width
        let sy = CGFloat(image.height) / imageFrame.height
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(
            x: (target.minX - imageFrame.minX) * sx,
            y: (imageFrame.maxY - target.maxY) * sy,
            width: target.width * sx,
            height: target.height * sy
        ))
        guard let result = context.makeImage() else { throw WindowOCRError.imageProcessing }
        return result
    }

    /// How far, summed over the four edges, a captured window's frame may be from the accessibility frame.
    /// The two agree to the point for the same window; a window farther off is another window.
    static let frameTolerance: CGFloat = 40

    /// The index of the window at `windowFrame`, or with no frame, of the window around the mask that fits it
    /// best. Nil when no window matches, so another window of the app is never read in its place.
    static func matchingWindow(_ frames: [CGRect], windowFrame: CGRect, mask: CGRect) -> Int? {
        if windowFrame.isEmpty {
            let center = CGPoint(x: mask.midX, y: mask.midY)
            return frames.indices.filter { frames[$0].contains(center) }
                .min { frameDistance(frames[$0], mask) < frameDistance(frames[$1], mask) }
        }
        guard let best = frames.indices.min(by: {
            frameDistance(frames[$0], windowFrame) < frameDistance(frames[$1], windowFrame)
        }), frameDistance(frames[best], windowFrame) <= frameTolerance else { return nil }
        return best
    }

    private static func frameDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}
