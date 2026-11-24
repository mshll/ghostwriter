import ApplicationServices
import CoreGraphics
import GWCore
import Testing
@testable import ScreenContext

@Suite struct RecentWindowSelectionTests {
    private let notes = WindowHandle(element: AXUIElementCreateApplication(101), pid: 1)
    private let otherNotesWindow = WindowHandle(element: AXUIElementCreateApplication(102), pid: 1)
    private let browser = WindowHandle(element: AXUIElementCreateApplication(201), pid: 2)
    private let capturedAt = ContinuousClock.now

    private func entry(_ window: WindowHandle) -> RecentWindow {
        RecentWindow(
            window: window, app: AppIdentity(bundleID: "test", name: "Browser", pid: window.pid), title: "Product",
            urls: [], text: "A lightweight tent for two people.", capturedAt: capturedAt
        )
    }

    @Test func usesAnotherWindowForUpToTenMinutes() {
        let picked = RecentWindow.select(entry(browser), enabled: true, typingIn: notes, at: capturedAt + .seconds(600))
        #expect(picked?.window == browser)
        #expect(RecentWindow.select(entry(browser), enabled: true, typingIn: notes, at: capturedAt + .seconds(601)) == nil)
    }

    @Test func leavesOutTheWindowBeingTypedIn() {
        #expect(RecentWindow.select(entry(notes), enabled: true, typingIn: notes, at: capturedAt) == nil)
        #expect(RecentWindow.select(entry(notes), enabled: true, typingIn: otherNotesWindow, at: capturedAt) != nil)
    }

    @Test func usesNothingWhenTurnedOffOrEmpty() {
        #expect(RecentWindow.select(entry(browser), enabled: false, typingIn: notes, at: capturedAt) == nil)
        #expect(RecentWindow.select(nil, enabled: true, typingIn: notes, at: capturedAt) == nil)
    }

    @Test func usesTheWindowWhenTheTypingWindowIsUnknown() {
        #expect(RecentWindow.select(entry(browser), enabled: true, typingIn: nil, at: capturedAt) != nil)
    }
}

@Suite struct RecentWindowTextTests {
    private let title = TextChunk(text: "Trail Tent 2 - Outdoor Shop", frame: CGRect(x: 40, y: 120, width: 500, height: 30))
    private let heading = TextChunk(
        text: "Trail Tent 2, ultralight shelter", frame: CGRect(x: 40, y: 200, width: 500, height: 40)
    )
    private let price = TextChunk(
        text: "Price 249 dollars, ships in two days", frame: CGRect(x: 40, y: 260, width: 500, height: 30)
    )
    private let details = TextChunk(
        text: "Weighs 1.2 kg and packs to the size of a bottle.", frame: CGRect(x: 40, y: 320, width: 500, height: 30)
    )

    private func render(_ chunks: [TextChunk], maxCharacters: Int = 2000) -> [String] {
        RecentWindowText.render(
            chunks, title: "Trail Tent 2 - Outdoor Shop", appName: "Safari", maxCharacters: maxCharacters
        )?.components(separatedBy: "\n") ?? []
    }

    @Test func readsFromTheTopDownWithoutTheTitle() {
        #expect(render([details, title, price, heading]) == [heading.text, price.text, details.text])
    }

    @Test func keepsTheTopWhenTheTextIsLong() {
        let budget = heading.text.count + price.text.count + 1
        #expect(render([details, price, heading], maxCharacters: budget) == [heading.text, price.text])
    }

    @Test func noReadableTextGivesNone() {
        #expect(RecentWindowText.render([], title: nil, appName: "Safari", maxCharacters: 2000) == nil)
    }
}
