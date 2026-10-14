import Foundation
import GWCore

public enum BuiltInAppRules {
    public static func rule(for bundleID: String) -> AppRule? {
        if let rule = appRules[bundleID] { return rule }
        if AppCatalog.isCodeEditor(bundleID) { return AppRule(bundleID: bundleID, codeEditorCompletions: false) }
        return nil
    }

    public static func isTerminal(_ bundleID: String) -> Bool {
        AppCatalog.terminals.contains(bundleID)
    }

    public static func domainRule(forHost host: String) -> AppRule? {
        let host = DomainPattern.normalize(host)
        return domainRules.first { DomainPattern.matches($0.pattern, host: host) }?.rule
    }

    private static let appRules: [String: AppRule] = {
        var rules: [String: AppRule] = [:]
        func add(_ ids: some Sequence<String>, _ make: (String) -> AppRule) {
            for id in ids {
                rules[id] = (rules[id] ?? AppRule(bundleID: id)).merged(with: make(id))
            }
        }
        add(AppCatalog.passwordManagers) { AppRule(bundleID: $0, completionsEnabled: false, recordWriting: false) }
        add(AppCatalog.completionsOff) { AppRule(bundleID: $0, completionsEnabled: false) }
        add(AppCatalog.codeEditors) { AppRule(bundleID: $0, codeEditorCompletions: false) }
        add(AppCatalog.vsCodeForks) { AppRule(bundleID: $0, codeEditorCompletions: false) }
        add(AppCatalog.needsEnhancedUserInterface) { AppRule(bundleID: $0, needsEnhancedUserInterface: true) }
        add(AppCatalog.singleCharacterInsertion) { AppRule(bundleID: $0, insertionMode: .keystrokes(chunkSize: 1)) }
        return rules
    }()

    private static let domainRules: [(pattern: String, rule: AppRule)] = {
        let searchEngines = [
            "figma.com", "google.*", "google.co.uk", "google.co.jp", "google.co.in", "google.com.au",
            "google.com.br", "google.com.mx", "bing.*", "duckduckgo.com", "kagi.com",
        ]
        let pasteHosts = ["docs.google.com", "*.sharepoint.com", "*.atlassian.net"]
        return searchEngines.map { ($0, AppRule(bundleID: "domain:\($0)", completionsEnabled: false)) }
            + pasteHosts.map { ($0, AppRule(bundleID: "domain:\($0)", insertionMode: .paste)) }
    }()
}

enum DomainPattern {
    static func normalize(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    static func matches(_ pattern: String, host: String) -> Bool {
        var core = Substring(pattern.lowercased())
        let anySubdomain = core.hasPrefix("*.")
        let anyTLD = core.hasSuffix(".*")
        if anySubdomain { core = core.dropFirst(2) }
        if anyTLD { core = core.dropLast(2) }
        guard !core.isEmpty, !core.contains("*") else { return false }

        var base = Substring(host)
        if anyTLD {
            guard let dot = base.lastIndex(of: ".") else { return false }
            base = base[..<dot]
        }
        if base == core { return true }
        return anySubdomain && base.hasSuffix("." + core)
    }

    static func matchesAny(_ patterns: [String], host: String) -> Bool {
        patterns.contains { matches($0, host: host) }
    }
}

enum AppCatalog {
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "company.thebrowser.Browser", "company.thebrowser.browser",
        "company.thebrowser.dia", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "app.zen-browser.zen", "org.mozilla.com.zen.browser", "com.kagi.kagimacOS", "com.openai.atlas",
        "ai.perplexity.comet", "net.imput.helium", "com.naver.Whale", "ru.yandex.desktop.yandex-browser",
        "com.pushplaylabs.sidekick", "com.ghostbrowser.gb1", "com.bookry.wavebox",
    ]

    /// Browsers where `AXEnhancedUserInterface` must never be written: it breaks window animation and positioning.
    static let enhancedUserInterfaceBlocked: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "com.mitchellh.ghostty.debug", "org.alacritty", "io.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
        "co.zeit.hyper", "org.tabby", "com.cmuxterm.app",
    ]

    static let vsCodeForks: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "com.vscodium", "com.stablyai.orca",
    ]

    static let codeEditors: Set<String> = [
        "com.apple.dt.Xcode", "com.apple.Xcode", "com.apple.dt.IDE.Cocoa-Simulator", "com.apple.InterfaceBuilder3",
        "com.sublimetext.2", "com.sublimetext.3", "com.sublimetext.4", "com.github.atom", "com.google.android.studio",
        "com.google.android.studio-EAP", "com.panic.Nova", "com.mathworks.matlab", "org.rstudio.RStudio",
        "org.editra.Editra", "com.mrFridge.Tincta", "se.hunch.kod",
    ]

    static func isCodeEditor(_ bundleID: String) -> Bool {
        codeEditors.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.") || bundleID.hasPrefix("dev.zed.")
    }

    static let passwordManagers: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword", "com.agilebits.onepassword7", "com.apple.Passwords",
        "com.lastpass.lastpassmacdesktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
        "com.dashlane.Dashlane", "com.bitwarden.desktop", "com.callpod.keepermac.lite",
        "com.keepersecurity.passwordmanager", "com.sibersystems.RoboFormMac", "com.nordsec.nordpass",
        "in.sinew.Enpass-Desktop", "com.ascendo.DataVaultMac", "me.proton.pass.electron", "com.mseven.msecuremac",
        "com.symantec.NortonPasswordManager.combined", "org.keepassx.keepassx", "org.keepassxc.keepassxc",
        "com.selznick.PasswordWallet", "com.outercorner.Secrets", "com.outercorner.Secrets-setapp",
        "com.outercorner.osx.Secrets", "com.outercorner.Secrets-safari",
    ]

    static let completionsOff: Set<String> = [
        "com.apple.finder", "com.apple.iCal", "com.microsoft.Excel", "com.apple.Preview", "pl.maketheweb.cleanshotx",
        "com.figma.Desktop", "com.runningwithcrayons.Alfred", "at.obdev.LaunchBar", "com.apple.systempreferences",
        "org.datavyu.datavyu",
    ]

    static let needsEnhancedUserInterface: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "com.google.Chrome.dev",
        "org.chromium.Chromium", "com.vivaldi.Vivaldi", "ru.yandex.desktop.yandex-browser", "com.operasoftware.Opera",
        "com.brave.Browser", "com.ghostbrowser.gb1", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev", "com.bookry.wavebox", "net.imput.helium", "org.mozilla.thunderbird",
        "eu.betterbird.Betterbird", "com.microsoft.Word", "com.microsoft.Outlook", "com.microsoft.teams2",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "app.zen-browser.zen",
        "org.mozilla.com.zen.browser", "com.pushplaylabs.sidekick", "company.thebrowser.Browser",
        "company.thebrowser.browser", "company.thebrowser.dia", "de.iridiumbrowser", "com.naver.Whale",
        "com.openai.atlas", "com.openai.atlas.web", "ai.perplexity.comet", "com.viber.osx", "com.apple.iWork.Pages",
        "com.apple.iWork.Keynote", "com.apple.iWork.Numbers", "com.apple.Pages", "com.apple.Keynote",
        "com.apple.Numbers", "md.obsidian", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "notion.id",
        "com.linear", "abnerworks.Typora",
    ]

    static let singleCharacterInsertion: Set<String> = [
        "com.finaldraft.finaldraft.v12", "com.finaldraft.finaldraft.v13", "com.freron.MailMate",
    ]

    static let ignoresSizeThresholds: Set<String> = ["com.apple.MobileSMS"]

    static let mailApps: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.readdle.SparkDesktop",
        "it.bloop.airmail2", "com.freron.MailMate", "com.mimestream.Mimestream", "org.mozilla.thunderbird",
        "eu.betterbird.Betterbird", "com.superhuman.electron", "com.smallcubed.mailmaven", "com.canarymail.mac",
    ]

    static let mailHosts = [
        "mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com", "app.fastmail.com",
        "mail.proton.me", "mail.yahoo.com", "app.hey.com", "mail.zoho.com",
    ]

    static let chatApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "com.hnc.Discord", "com.microsoft.teams2",
        "com.microsoft.teams", "ru.keepcoder.Telegram", "org.telegram.desktop", "net.whatsapp.WhatsApp",
        "desktop.WhatsApp", "org.whispersystems.signal-desktop", "com.viber.osx", "com.facebook.archon",
        "im.riot.app", "ch.threema.threema-desktop", "com.skype.skype",
    ]

    static let chatHosts = [
        "*.slack.com", "discord.com", "web.whatsapp.com", "web.telegram.org", "teams.microsoft.com", "teams.live.com",
        "messenger.com", "chat.google.com", "app.element.io",
    ]

    static let aiApps: Set<String> = [
        "com.openai.chat", "com.anthropic.claudefordesktop", "com.google.GeminiMacOS", "ai.perplexity.mac",
    ]

    static let aiHosts = [
        "chatgpt.com", "chat.openai.com", "claude.ai", "gemini.google.com", "perplexity.ai", "chat.mistral.ai",
        "grok.com", "copilot.microsoft.com", "chat.deepseek.com", "aistudio.google.com", "poe.com",
    ]

    static let documentApps: Set<String> = [
        "com.apple.Notes", "com.apple.iWork.Pages", "com.apple.Pages", "com.microsoft.Word", "notion.id",
        "md.obsidian", "com.apple.TextEdit", "net.shinyfrog.bear", "com.ulyssesapp.mac", "pro.writer.mac",
        "com.lukilabs.lukiapp", "com.literatureandlatte.scrivener3", "abnerworks.Typora", "com.agiletortoise.Drafts-OSX",
        "com.microsoft.onenote.mac", "com.evernote.Evernote",
    ]

    static let documentHosts = ["docs.google.com", "notion.so", "*.notion.site", "coda.io", "quip.com"]
}
