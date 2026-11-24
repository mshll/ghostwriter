import Foundation
import GWCore
import Testing
@testable import Capture

@Suite struct WindowSourceAppTests {
    @Test func readsAppsWhereSuggestionsAndWindowTextAreOn() {
        #expect(WindowSourceRules.allowsApp("com.apple.Safari", rule: AppRule(bundleID: "com.apple.Safari")))
        #expect(WindowSourceRules.allowsApp("com.apple.Notes", rule: AppRule(bundleID: "com.apple.Notes", completionsEnabled: true)))
    }

    @Test func neverReadsPasswordManagersOrTerminals() {
        let turnedOn = AppRule(bundleID: "com.1password.1password", completionsEnabled: true, screenContextEnabled: true)
        #expect(!WindowSourceRules.allowsApp("com.1password.1password", rule: turnedOn))
        #expect(!WindowSourceRules.allowsApp("com.apple.Terminal", rule: AppRule(bundleID: "com.apple.Terminal")))
    }

    @Test func skipsExcludedAppsAndAppsWithWindowTextOff() {
        #expect(!WindowSourceRules.allowsApp("com.example.chat", rule: AppRule(bundleID: "com.example.chat", completionsEnabled: false)))
        #expect(!WindowSourceRules.allowsApp("com.example.chat", rule: AppRule(bundleID: "com.example.chat", screenContextEnabled: false)))
    }

    @Test func readsCodeEditorsOnlyWithTheirSuggestionsOn() {
        #expect(!WindowSourceRules.allowsApp("com.apple.dt.Xcode", rule: AppRule(bundleID: "com.apple.dt.Xcode")))
        let on = AppRule(bundleID: "com.apple.dt.Xcode", codeEditorCompletions: true)
        #expect(WindowSourceRules.allowsApp("com.apple.dt.Xcode", rule: on))
    }
}

@Suite struct WindowSourcePageTests {
    private let safari = "com.apple.Safari"

    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    private func allows(_ urls: [URL], in bundleID: String = "com.apple.Safari", userRules: [String: AppRule] = [:]) -> Bool {
        WindowSourceRules.allowsPages(urls, in: bundleID) { userRules[$0] }
    }

    @Test func readsAnOrdinaryPage() throws {
        let page = try url("https://www.shop.example/tent")
        #expect(allows([page]))
        #expect(WindowSourceRules.host(of: [page], in: safari) == "shop.example")
    }

    @Test func skipsSitesExcludedByDefaultOrByTheUser() throws {
        let page = try url("https://www.shop.example/tent")
        #expect(!allows([try url("https://www.google.com/search?q=tent")]))
        let off = AppRule(bundleID: "domain:shop.example", completionsEnabled: false)
        #expect(!allows([page], userRules: ["domain:shop.example": off]))
        let noWindowText = AppRule(bundleID: "domain:shop.example", screenContextEnabled: false)
        #expect(!allows([page], userRules: ["domain:shop.example": noWindowText]))
    }

    @Test func skipsBrowserWindowsWithoutAWebPage() throws {
        #expect(!allows([]))
        #expect(!allows([try url("about:blank")]))
        #expect(!allows([try url("https://shop.example/tent"), try url("chrome-extension://abc/popup.html")]))
    }

    @Test func readsOtherAppsWithoutAddressesAndNamesNoSite() throws {
        #expect(allows([], in: "com.apple.Notes"))
        #expect(WindowSourceRules.host(of: [try url("https://app.slack.com/client")], in: "com.tinyspeck.slackmacgap") == nil)
    }
}
