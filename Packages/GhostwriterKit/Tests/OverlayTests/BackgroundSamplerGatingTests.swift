import Foundation
import ScreenCaptureKit
import Testing
@testable import Overlay

@Suite struct BackgroundSamplerGatingTests {
    @Test func waitsAnHourAfterTheUserDeclinedCapture() {
        #expect(BackgroundSampler.pause(after: SCStreamError(.userDeclined)) == .seconds(3600))
    }

    @Test func waitsBrieflyAfterOtherFailures() {
        #expect(BackgroundSampler.pause(after: SCStreamError(.failedToStart)) == .seconds(30))
        #expect(BackgroundSampler.pause(after: CocoaError(.featureUnsupported)) == .seconds(30))
    }

    @Test func samplesTheSmallestWindowAroundTheStrip() {
        let main = CGRect(x: 100, y: 100, width: 1000, height: 800)
        let sheet = CGRect(x: 300, y: 130, width: 500, height: 300)
        let elsewhere = CGRect(x: 1200, y: 100, width: 400, height: 400)
        let strip = CGRect(x: 320, y: 200, width: 460, height: 18)
        #expect(BackgroundSampler.window(holding: strip, frames: [main, sheet, elsewhere]) == 1)
        #expect(BackgroundSampler.window(holding: strip, frames: [main, elsewhere]) == 0)
        #expect(BackgroundSampler.window(holding: strip, frames: [elsewhere]) == nil)
    }

    @MainActor @Test func capturesNothingUntilTheAppAllowsIt() {
        #expect(!BackgroundSampling.isAllowed())
    }
}
