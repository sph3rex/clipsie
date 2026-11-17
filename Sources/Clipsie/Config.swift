import Foundation

enum AppPaths {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Clipsie", isDirectory: true)
    private static let oldSupport = support.deletingLastPathComponent().appendingPathComponent("ClipboardManager", isDirectory: true)
    static let database = support.appendingPathComponent("history.sqlite")
    static let config = support.appendingPathComponent("config.json")
    static let commands = support.appendingPathComponent("commands.json")
    static let scripts = support.appendingPathComponent("scripts", isDirectory: true)
    static let plugins = support.appendingPathComponent("plugins", isDirectory: true)
    static let favicons = support.appendingPathComponent("favicons", isDirectory: true)

    static func createDirectories() throws {
        if !FileManager.default.fileExists(atPath: support.path), FileManager.default.fileExists(atPath: oldSupport.path) {
            try FileManager.default.moveItem(at: oldSupport, to: support)
        }
        for directory in [scripts, favicons] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

struct SearchProvider: Codable {
    var name: String
    var url: String
    var symbol: String?
    var icon: String?
    var favicon: Bool?

    var iconURL: URL? {
        if let icon { return URL(string: icon) }
        guard favicon ?? true, let host = URL(string: url.replacingOccurrences(of: "{q}", with: ""))?.host else { return nil }
        return URL(string: "https://\(host)/favicon.ico")
    }

    func url(for text: String) -> URL? {
        let query = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: url.replacingOccurrences(of: "{q}", with: encoded))
    }
}

struct Config: Codable {
    var maxItems = 50_000
    var maxItemBytes = 50 * 1024 * 1024
    var historyHotkey = "cmd+shift+v"
    var pastePlainHotkey = "cmd+alt+shift+v"
    var menuItemCount = 20
    var showPreview = true
    var commandsPrefix = ">"
    var generatorsPrefix = ">>"
    var commandsShortcut = "cmd+k"
    var generatorsShortcut = "cmd+shift+e"
    var multiPasteSeparator = "\n"
    var quickPasteModifiers = "cmd"
    var searchProviders: [SearchProvider] = [
        SearchProvider(name: "Google", url: "https://www.google.com/search?q={q}", symbol: "magnifyingglass"),
        SearchProvider(name: "Google AI Mode", url: "https://www.google.com/search?q={q}&udm=50",
                       symbol: "sparkle.magnifyingglass", favicon: false),
        SearchProvider(name: "ChatGPT", url: "https://chatgpt.com/?q={q}", symbol: "bubble.left.and.bubble.right"),
        SearchProvider(name: "Claude", url: "https://claude.ai/new?q={q}", symbol: "asterisk"),
    ]
    var linkPreviews = false
    var searchMode = SearchMode.exact
    var saveText = true
    var saveImages = true
    var saveFiles = true
    var clearHistoryOnQuit = false
    var keepTagsOnQuit = [Store.importantTag]
    var ocr = true
    var ocrLanguages: [String] = []
    var pollInterval = 0.3
    var pasteDelayMs = 50
    var pasteDelayMsByApp: [String: Int] = ["com.jetbrains.": 250, "com.google.android.studio": 250]
    var pasteShortcutByApp: [String: String] = [:]
    var mergeCopiesWithinMsByApp: [String: Int] = ["com.jetbrains.": 1000]
    var plainTextApps: [String] = []
    var ignoredApps: [String] = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? d.maxItems
        maxItemBytes = try c.decodeIfPresent(Int.self, forKey: .maxItemBytes) ?? d.maxItemBytes
        historyHotkey = try c.decodeIfPresent(String.self, forKey: .historyHotkey) ?? d.historyHotkey
        pastePlainHotkey = try c.decodeIfPresent(String.self, forKey: .pastePlainHotkey) ?? d.pastePlainHotkey
        menuItemCount = try c.decodeIfPresent(Int.self, forKey: .menuItemCount) ?? d.menuItemCount
        showPreview = try c.decodeIfPresent(Bool.self, forKey: .showPreview) ?? d.showPreview
        commandsPrefix = try c.decodeIfPresent(String.self, forKey: .commandsPrefix) ?? d.commandsPrefix
        generatorsPrefix = try c.decodeIfPresent(String.self, forKey: .generatorsPrefix) ?? d.generatorsPrefix
        commandsShortcut = try c.decodeIfPresent(String.self, forKey: .commandsShortcut) ?? d.commandsShortcut
        generatorsShortcut = try c.decodeIfPresent(String.self, forKey: .generatorsShortcut) ?? d.generatorsShortcut
        multiPasteSeparator = try c.decodeIfPresent(String.self, forKey: .multiPasteSeparator) ?? d.multiPasteSeparator
        quickPasteModifiers = try c.decodeIfPresent(String.self, forKey: .quickPasteModifiers) ?? d.quickPasteModifiers
        searchProviders = try c.decodeIfPresent([SearchProvider].self, forKey: .searchProviders) ?? d.searchProviders
        linkPreviews = try c.decodeIfPresent(Bool.self, forKey: .linkPreviews) ?? d.linkPreviews
        searchMode = try c.decodeIfPresent(SearchMode.self, forKey: .searchMode) ?? d.searchMode
        saveText = try c.decodeIfPresent(Bool.self, forKey: .saveText) ?? d.saveText
        saveImages = try c.decodeIfPresent(Bool.self, forKey: .saveImages) ?? d.saveImages
        saveFiles = try c.decodeIfPresent(Bool.self, forKey: .saveFiles) ?? d.saveFiles
        clearHistoryOnQuit = try c.decodeIfPresent(Bool.self, forKey: .clearHistoryOnQuit) ?? d.clearHistoryOnQuit
        keepTagsOnQuit = try c.decodeIfPresent([String].self, forKey: .keepTagsOnQuit) ?? d.keepTagsOnQuit
        ocr = try c.decodeIfPresent(Bool.self, forKey: .ocr) ?? d.ocr
        ocrLanguages = try c.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? d.ocrLanguages
        pollInterval = try c.decodeIfPresent(Double.self, forKey: .pollInterval) ?? d.pollInterval
        pasteDelayMs = try c.decodeIfPresent(Int.self, forKey: .pasteDelayMs) ?? d.pasteDelayMs
        pasteDelayMsByApp = try c.decodeIfPresent([String: Int].self, forKey: .pasteDelayMsByApp) ?? d.pasteDelayMsByApp
        pasteShortcutByApp = try c.decodeIfPresent([String: String].self, forKey: .pasteShortcutByApp) ?? d.pasteShortcutByApp
        mergeCopiesWithinMsByApp = try c.decodeIfPresent([String: Int].self, forKey: .mergeCopiesWithinMsByApp)
            ?? d.mergeCopiesWithinMsByApp
        plainTextApps = try c.decodeIfPresent([String].self, forKey: .plainTextApps) ?? d.plainTextApps
        ignoredApps = try c.decodeIfPresent([String].self, forKey: .ignoredApps) ?? d.ignoredApps
    }

    static func set(_ key: String, to value: Any) throws {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: AppPaths.config)) as? [String: Any] else {
            throw StoreError(description: "config.json doesn't contain a JSON object")
        }
        var updated = object
        updated[key] = value
        try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: AppPaths.config, options: .atomic)
    }

    static func load() throws -> Config {
        if !FileManager.default.fileExists(atPath: AppPaths.config.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Config()).write(to: AppPaths.config)
        }
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: AppPaths.config))
    }
}
