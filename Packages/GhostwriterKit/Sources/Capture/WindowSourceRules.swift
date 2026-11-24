import Foundation
import GWCore

/// Which windows may lend their text to suggestions in another window: the apps and sites whose window text
/// Ghostwriter reads while the user types in them, minus terminals, whose text is read only as an agent's transcript.
public enum WindowSourceRules {
    /// `rule` is the app's effective rule, with the built-in rule and the app scope applied.
    public static func allowsApp(_ bundleID: String, rule: AppRule) -> Bool {
        if AppCatalog.passwordManagers.contains(bundleID) || AppCatalog.terminals.contains(bundleID) { return false }
        if AppCatalog.isCodeEditor(bundleID), rule.codeEditorCompletions != true { return false }
        return rule.completionsEnabled != false && rule.screenContextEnabled != false
    }

    /// `userRule` returns the user's rule for a `domain:<host>` key. A browser window without a web address is
    /// refused: its site rules cannot be checked.
    public static func allowsPages(_ urls: [URL], in bundleID: String, userRule: (String) -> AppRule?) -> Bool {
        let isBrowser = AppCatalog.browsers.contains(bundleID)
        if urls.contains(where: { !PageScheme.isReadable($0, inBrowser: isBrowser) }) { return false }
        let pages = webPages(urls)
        if isBrowser, pages.isEmpty { return false }
        return pages.allSatisfy { url, host in
            let key = "domain:\(host)"
            let rule = (BuiltInAppRules.domainRule(for: url) ?? AppRule(bundleID: key)).merged(with: userRule(key))
            return rule.completionsEnabled != false && rule.screenContextEnabled != false
        }
    }

    /// The site a browser window shows; nil for other apps.
    public static func host(of urls: [URL], in bundleID: String) -> String? {
        AppCatalog.browsers.contains(bundleID) ? webPages(urls).first?.host : nil
    }

    private static func webPages(_ urls: [URL]) -> [(url: URL, host: String)] {
        urls.compactMap { url in
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host().map(DomainPattern.normalize) else { return nil }
            return (url, host)
        }
    }
}
