import AppKit
import ServiceManagement
import UniformTypeIdentifiers

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, HistoryActions {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var config = Config()
    private var commands: [UserCommand] = []
    private var store: Store!
    private let monitor = ClipboardMonitor()
    private let paster = Paster()
    private var history: HistoryWindowController!
    private var ocr: OCR!
    private var statusItem: NSStatusItem!
    private var menuTargetApp: NSRunningApplication?
    private var isImporting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        installEditMenu()
        do {
            try AppPaths.createDirectories()
            Plugins.installDefaults()
            store = try openStore()
        } catch {
            showError("Cannot open clipboard history", "\(error)")
            NSApp.terminate(nil)
            return
        }
        guard store != nil else {
            NSApp.terminate(nil)
            return
        }

        history = HistoryWindowController(store: store)
        history.actions = self
        ocr = OCR(store: store)
        let store = self.store!
        ScriptEngine.historyProvider = { count in store.recentTexts(limit: count) }
        ocr.onRecognized = { [weak self] _ in self?.history.refreshIfVisible() }
        paster.onClipboardWritten = { [weak self] in self?.monitor.skipCurrentChange() }
        monitor.onCapture = { [weak self] capture in self?.handleCapture(capture) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()

        reloadSettings()
        _ = Paster.isTrusted(prompt: true)
    }

    private func installEditMenu() {
        let mainMenu = NSMenu()
        mainMenu.addItem(NSMenuItem())
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func reloadSettings() {
        do {
            config = try Config.load()
        } catch {
            showError("config.json is invalid — using defaults", "\(error)")
            config = Config()
        }
        do {
            let loaded = try UserCommand.load()
            commands = loaded.commands
            if !loaded.skipped.isEmpty {
                showError("Automatic commands can only run JavaScript",
                          "These were skipped, because they use a shell \"command\": "
                          + loaded.skipped.map { "“\($0)”" }.joined(separator: ", ")
                          + ".\n\nAutomatic commands see everything you copy, so they run sandboxed only. "
                          + "Rewrite them with \"script\" (see the README), or set \"enabled\": false.")
            }
        } catch {
            showError("commands.json is invalid — no commands loaded", "\(error)")
            commands = []
        }
        ScriptEngine.commands.reset()
        ScriptEngine.plugins.reset()
        monitor.maxItemBytes = config.maxItemBytes
        monitor.ignoredApps = Set(config.ignoredApps)
        monitor.start(interval: config.pollInterval)
        paster.pasteDelay = Double(config.pasteDelayMs) / 1000
        paster.pasteDelaysByApp = config.pasteDelayMsByApp.mapValues { Double($0) / 1000 }
        paster.pasteShortcutsByApp = config.pasteShortcutByApp.compactMapValues { string in
            guard let shortcut = Shortcut(string) else {
                showError("Invalid paste shortcut “\(string)” in pasteShortcutByApp", "Use a form like \"ctrl+v\".")
                return nil
            }
            return shortcut
        }
        history.commands = commands.filter { $0.type == .menu }
        history.showsPreview = config.showPreview
        history.linkPreviews = config.linkPreviews
        history.searchProviders = config.searchProviders
        history.plugins = Plugins.load()
        if config.quickPasteModifiers.isEmpty {
            history.quickPasteModifiers = nil
        } else if let modifiers = Shortcut.modifiers(config.quickPasteModifiers), !modifiers.isEmpty {
            history.quickPasteModifiers = modifiers
        } else {
            showError("Invalid quickPasteModifiers “\(config.quickPasteModifiers)” in config.json",
                      "Use modifiers like \"cmd\", \"ctrl\", \"alt\" or \"ctrl+alt\", or \"\" to turn quick paste off.")
            history.quickPasteModifiers = .command
        }
        history.commandsPrefix = config.commandsPrefix
        history.generatorsPrefix = config.generatorsPrefix
        history.commandsShortcut = paletteShortcut(config.commandsShortcut, key: "commandsShortcut")
        history.generatorsShortcut = paletteShortcut(config.generatorsShortcut, key: "generatorsShortcut")
        store.prune(maxItems: config.maxItems)
        ocr.isEnabled = config.ocr
        ocr.languages = config.ocrLanguages
        ocr.backfill()
        registerHotKeys()
    }

    private func paletteShortcut(_ string: String, key: String) -> Shortcut? {
        guard !string.isEmpty else { return nil }
        guard let shortcut = Shortcut(string), !shortcut.modifiers.isDisjoint(with: [.command, .control]) else {
            showError("Invalid \(key) “\(string)” in config.json",
                      "Use a shortcut with cmd or ctrl, e.g. \"cmd+shift+e\", or \"\" for none.")
            return nil
        }
        return shortcut
    }

    private func registerHotKeys() {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        let registered = Shortcut(config.historyHotkey).map {
            center.register($0, action: { [weak self] in self?.toggleHistory() })
        } ?? false
        if !registered {
            showError("Cannot register shortcut “\(config.historyHotkey)”",
                      "It is invalid or already used by another app. Change historyHotkey in config.json.")
        }
        if !config.pastePlainHotkey.isEmpty {
            let registered = Shortcut(config.pastePlainHotkey).map {
                center.register($0, action: { [weak self] in self?.pasteClipboardAsPlainText() })
            } ?? false
            if !registered {
                showError("Cannot register shortcut “\(config.pastePlainHotkey)”",
                          "It is invalid or already used by another app. Change pastePlainHotkey in config.json (\"\" disables it).")
            }
        }
        for command in commands where command.type == .menu {
            guard let string = command.globalShortcut else { continue }
            guard let shortcut = Shortcut(string),
                  center.register(shortcut, action: { [weak self] in self?.runOnLatest(command) }) else {
                showError("Cannot register shortcut “\(string)” for “\(command.name)”", "It is invalid or already in use.")
                continue
            }
        }
    }

    private func handleCapture(_ capture: Capture) {
        let automatic = commands.filter {
            $0.type == .automatic && $0.applies(to: capture.text, sourceApp: capture.sourceApp)
        }
        runAutomatic(automatic[...], on: capture)
    }

    private func runAutomatic(_ remaining: ArraySlice<UserCommand>, on capture: Capture) {
        guard let command = remaining.first else {
            save(capture)
            return
        }
        let started = execute(command, input: capture.text ?? "", itemID: nil, sourceApp: capture.sourceApp,
                              reps: capture.representations) { [weak self] result in
            guard let self else { return }
            if command.ignore || result.status == UserCommand.ignoreExitCode { return }
            var next = capture
            if result.status != 0 {
                NSLog("Clipsie: automatic command “\(command.name)” failed (\(result.status)): \(result.error)")
            } else if command.output == .replace {
                next = Capture(text: Self.trimmed(result.output, input: capture.text ?? ""), sourceApp: capture.sourceApp)
            } else if command.output == .newItem {
                self.save(Capture(text: Self.trimmed(result.output, input: capture.text ?? ""), sourceApp: capture.sourceApp))
            }
            self.runAutomatic(remaining.dropFirst(), on: next)
        }
        if !started && !command.ignore { runAutomatic(remaining.dropFirst(), on: capture) }
    }

    private func save(_ capture: Capture) {
        let id = store.save(capture, maxItems: config.maxItems)
        if let id, Content.imageData(capture.representations) != nil { ocr.recognize(id) }
        history.refreshIfVisible()
    }

    func paste(itemID: Int64, plainText: Bool, target: NSRunningApplication?) {
        let reps = store.representations(for: itemID)
        let plain = plainText || (wantsPlainText(target) && Content.isFormattedText(reps))
        if plainText, Content.text(reps) == nil, let recognized = store.ocrText(for: itemID) {
            guard paster.write(text: recognized) else {
                NSSound.beep()
                return
            }
            deliverPaste(to: target)
            return
        }
        guard !reps.isEmpty, paster.write(reps, plainTextOnly: plain) else {
            NSSound.beep()
            return
        }
        store.touch(itemID)
        deliverPaste(to: target)
    }

    func pasteFenced(itemID: Int64, with character: Character, target: NSRunningApplication?) {
        guard let text = Content.text(store.representations(for: itemID)),
              paster.write(text: Content.fenced(text, with: character)) else {
            NSSound.beep()
            return
        }
        deliverPaste(to: target)
    }

    func pasteText(_ text: String, target: NSRunningApplication?) {
        guard paster.write(text: text) else { return }
        save(Capture(text: text, sourceApp: nil))
        deliverPaste(to: target)
    }

    func pasteItems(_ ids: [Int64], target: NSRunningApplication?) {
        let texts = ids.compactMap { Content.text(store.representations(for: $0)) }
        guard !texts.isEmpty, paster.write(text: texts.joined(separator: config.multiPasteSeparator)) else {
            NSSound.beep()
            return
        }
        deliverPaste(to: target)
    }

    func copyText(_ text: String) {
        guard paster.write(text: text) else { return }
        save(Capture(text: text, sourceApp: nil))
    }

    func copy(itemID: Int64) {
        let reps = store.representations(for: itemID)
        guard !reps.isEmpty, paster.write(reps, plainTextOnly: false) else {
            NSSound.beep()
            return
        }
        store.touch(itemID)
    }

    func run(_ command: UserCommand, itemID: Int64?, target: NSRunningApplication?) {
        runCommand(command, itemID: itemID, target: target)
    }

    private func wantsPlainText(_ target: NSRunningApplication?) -> Bool {
        guard let bundleID = (target ?? NSWorkspace.shared.frontmostApplication)?.bundleIdentifier else { return false }
        return config.plainTextApps.contains { bundleID.hasPrefix($0) }
    }

    private func pasteClipboardAsPlainText() {
        let pasteboard = NSPasteboard.general
        let text = pasteboard.string(forType: .string)
            ?? pasteboard.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil)?.string }
        guard let text, paster.write(text: text) else {
            NSSound.beep()
            return
        }
        deliverPaste(to: NSWorkspace.shared.frontmostApplication)
    }

    private func deliverPaste(to target: NSRunningApplication?) {
        if history.isVisible { history.hide() }
        if NSApp.isActive { NSApp.hide(nil) }
        paster.paste(into: target)
    }

    private func runOnLatest(_ command: UserCommand) {
        runCommand(command, itemID: store.latestID(), target: NSWorkspace.shared.frontmostApplication)
    }

    private func runCommand(_ command: UserCommand, itemID: Int64?, target: NSRunningApplication?) {
        var reps: [Representation] = []
        if command.input == .item {
            guard let itemID else { return }
            reps = store.representations(for: itemID)
        }
        let input = Content.text(reps) ?? ""
        guard command.applies(to: input, sourceApp: nil) else { return }
        execute(command, input: input, itemID: itemID, sourceApp: nil, reps: reps) { [weak self] result in
            self?.finish(command, result: result, input: input, itemID: itemID, target: target)
        }
    }

    @discardableResult
    private func execute(_ command: UserCommand, input: String, itemID: Int64?, sourceApp: String?,
                         reps: [Representation], completion: @escaping (CommandResult) -> Void) -> Bool {
        let engine: UserCommand.Engine?
        do {
            engine = try command.engine()
        } catch {
            completion(CommandResult(status: 1, output: "", error: "\(error)"))
            return true
        }
        switch engine {
        case nil:
            return false
        case .shell(let script):
            CommandRunner.run(script, input: input,
                              environment: scriptEnvironment(itemID: itemID, sourceApp: sourceApp, reps: reps),
                              timeout: command.timeout, completion: completion)
        case .javaScript(let source):
            var types: [String] = []
            for rep in reps where !types.contains(rep.type) { types.append(rep.type) }
            let scriptInput = ScriptInput(text: input, itemID: itemID, sourceApp: sourceApp, types: types)
            ScriptEngine.commands.run(source, name: command.name, input: scriptInput, timeout: command.timeout) { result in
                switch result {
                case .success(.nothing):
                    completion(CommandResult(status: 0, output: "", error: ""))
                case .success(.ignore):
                    let status = command.type == .automatic ? UserCommand.ignoreExitCode : 0
                    completion(CommandResult(status: status, output: "", error: ""))
                case .success(.text(let text, _)):
                    completion(CommandResult(status: 0, output: text, error: ""))
                case .failure(let error):
                    completion(CommandResult(status: 1, output: "", error: error.message))
                }
            }
        }
        return true
    }

    private func finish(_ command: UserCommand, result: CommandResult, input: String, itemID: Int64?,
                        target: NSRunningApplication?) {
        guard result.status == 0 else {
            showError("Command “\(command.name)” failed (exit \(result.status))",
                      result.error.isEmpty ? result.output : result.error)
            return
        }
        let output = Self.trimmed(result.output, input: input)
        guard !output.isEmpty || command.output == .none else {
            NSSound.beep()
            return
        }
        switch command.output {
        case .none:
            break
        case .paste:
            guard paster.write(text: output) else { return }
            save(Capture(text: output, sourceApp: nil))
            deliverPaste(to: target)
        case .copy:
            guard paster.write(text: output) else { return }
            save(Capture(text: output, sourceApp: nil))
        case .newItem:
            save(Capture(text: output, sourceApp: nil))
        case .replace:
            if let itemID, command.input == .item {
                store.replace(id: itemID, with: Capture(text: output, sourceApp: nil))
                history.refreshIfVisible()
            } else {
                save(Capture(text: output, sourceApp: nil))
            }
        }
    }

    private func scriptEnvironment(itemID: Int64?, sourceApp: String?, reps: [Representation]) -> [String: String] {
        [
            "CLIP_ITEM_ID": itemID.map { String($0) } ?? "",
            "CLIP_SOURCE_APP": sourceApp ?? "",
            "CLIP_TYPES": reps.map(\.type).joined(separator: "\n"),
            "CLIP_DATA_DIR": AppPaths.support.path,
        ]
    }

    private static func trimmed(_ output: String, input: String) -> String {
        guard output.hasSuffix("\n"), !input.hasSuffix("\n") else { return output }
        return String(output.dropLast())
    }

    @objc private func toggleHistory() {
        if history.isVisible {
            history.hide()
            NSApp.hide(nil)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        let isSelf = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        history.show(target: isSelf ? nil : front)
    }

    @objc private func showHistoryFromMenu() {
        history.show(target: menuTargetApp)
    }

    private func updateStatusIcon() {
        let image = monitor.isPaused
            ? NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Clipsie (paused)")
            : NSImage(named: "StatusIcon") ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipsie")
        image?.accessibilityDescription = monitor.isPaused ? "Clipsie (paused)" : "Clipsie"
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menuTargetApp = NSWorkspace.shared.frontmostApplication
        menu.removeAllItems()

        let rows = store.recentRows(limit: config.menuItemCount, in: .history)
        if rows.isEmpty {
            let empty = NSMenuItem(title: "History is empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for (index, row) in rows.enumerated() {
            let key = index < 10 ? String((index + 1) % 10) : ""
            let item = historyMenuItem(row, keyEquivalent: key)
            item.keyEquivalentModifierMask = []
            menu.addItem(item)
        }

        let tagged = store.recentRows(limit: 50, in: .tagged)
        if !tagged.isEmpty {
            let submenu = NSMenu()
            for row in tagged {
                submenu.addItem(historyMenuItem(row, keyEquivalent: ""))
            }
            let taggedItem = NSMenuItem(title: "Tagged", action: nil, keyEquivalent: "")
            taggedItem.submenu = submenu
            menu.addItem(.separator())
            menu.addItem(taggedItem)
        }

        do {
            let latest = store.latestID()
            let text = latest.flatMap { Content.text(store.representations(for: $0)) }
            let applicable = commands.filter {
                $0.type == .menu && ($0.input == .none || latest != nil) && $0.applies(to: text, sourceApp: nil)
            }
            if !applicable.isEmpty {
                let submenu = NSMenu()
                for command in applicable {
                    let item = NSMenuItem(title: command.name, action: #selector(runFromMenu(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = command.name
                    submenu.addItem(item)
                }
                let commandsItem = NSMenuItem(title: "Commands", action: nil, keyEquivalent: "")
                commandsItem.submenu = submenu
                menu.addItem(.separator())
                menu.addItem(commandsItem)
            }
        }

        menu.addItem(.separator())
        let hotkey = Shortcut(config.historyHotkey)?.display ?? config.historyHotkey
        addMenuItem(to: menu, "Show History…   \(hotkey)", #selector(showHistoryFromMenu))
        addMenuItem(to: menu, "Pause Capturing", #selector(togglePause)).state = monitor.isPaused ? .on : .off
        addMenuItem(to: menu, "Clear History…", #selector(clearHistory))
        addMenuItem(to: menu, "Remove Duplicates…", #selector(removeDuplicates))
        addMenuItem(to: menu, "Export as JSON…", #selector(exportHistory))
        addMenuItem(to: menu, isImporting ? "Importing…" : "Import from JSON…", #selector(importHistory))
        menu.addItem(.separator())
        addMenuItem(to: menu, "Edit Settings…", #selector(openConfig))
        addMenuItem(to: menu, "Edit Commands…", #selector(openCommands))
        addMenuItem(to: menu, "Reload Settings & Commands", #selector(reloadSettings))
        addMenuItem(to: menu, "Open Data Folder", #selector(openDataFolder))
        addMenuItem(to: menu, "Launch at Login", #selector(toggleLaunchAtLogin)).state =
            SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        addMenuItem(to: menu, "Quit", #selector(NSApplication.terminate(_:)), target: NSApp)
    }

    @discardableResult
    private func addMenuItem(to menu: NSMenu, _ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target ?? self
        menu.addItem(item)
        return item
    }

    private static func menuTitle(_ row: ItemRow) -> String {
        let text = row.title ?? row.preview
        let preview = text.count > 60 ? String(text.prefix(60)) + "…" : text
        return preview + (row.pinned ? "  📌" : "")
    }

    private func historyMenuItem(_ row: ItemRow, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: Self.menuTitle(row), action: #selector(pasteFromMenu(_:)), keyEquivalent: keyEquivalent)
        if row.title != nil { item.toolTip = row.preview }
        if let data = row.thumbnail, let image = NSImage(data: data) {
            let scale = 18 / max(image.size.width, image.size.height, 1)
            image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            item.image = image
        }
        item.target = self
        item.representedObject = row.id
        return item
    }

    @objc private func pasteFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64 else { return }
        let plain = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        paste(itemID: id, plainText: plain, target: menuTargetApp)
    }

    @objc private func runFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let command = commands.first(where: { $0.name == name }) else { return }
        runCommand(command, itemID: store.latestID(), target: menuTargetApp)
    }

    @objc private func togglePause() {
        monitor.isPaused.toggle()
        updateStatusIcon()
    }

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "All items except pinned ones will be removed from History. Tagged items are kept in Tagged. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            store.clear(keepPinned: true)
            history.refreshIfVisible()
        }
    }

    @objc private func removeDuplicates() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove duplicates?"
        alert.informativeText = "Items with exactly the same text as a newer item are deleted. The newest copy is kept and "
            + "gets their pin, title and tags. Images are left alone. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.removeDuplicates { [weak self] count in
            self?.history.refreshIfVisible()
            let done = NSAlert()
            done.messageText = count == 0 ? "No duplicates found" : "Removed \(count) duplicate\(count == 1 ? "" : "s")"
            NSApp.activate(ignoringOtherApps: true)
            done.runModal()
        }
    }

    @objc private func exportHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        panel.nameFieldStringValue = "Clipboard History \(day).json"
        panel.allowedContentTypes = [.json]
        let checkbox = NSButton(checkboxWithTitle: "Include all formats of text items (RTF, HTML, …) — larger file. Images are always included.",
                                target: nil, action: nil)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: checkbox.fittingSize.width + 40, height: 36))
        checkbox.frame.origin = NSPoint(x: 20, y: 8)
        accessory.addSubview(checkbox)
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.exportJSON(to: url, allFormats: checkbox.state == .on) { [weak self] result in
            switch result {
            case .success(let count):
                let alert = NSAlert()
                alert.messageText = "Exported \(count) items"
                alert.informativeText = "\(url.path)\n\nThe file isn't encrypted and may contain passwords or other secrets you copied."
                alert.addButton(withTitle: "Show in Finder")
                alert.addButton(withTitle: "OK")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            case .failure(let error):
                self?.showError("Export failed", "\(error)")
            }
        }
    }

    @objc private func importHistory() {
        guard !isImporting else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a file made with Export as JSON…. Items you already have are merged, not duplicated."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImporting = true
        HistoryImport.run(from: url, into: store, maxItemBytes: config.maxItemBytes) { [weak self] result in
            guard let self else { return }
            self.isImporting = false
            switch result {
            case .success(let summary):
                self.store.prune(maxItems: self.config.maxItems)
                self.ocr.backfill(again: true)
                self.history.refreshIfVisible()
                var lines = ["\(summary.added) added, \(summary.merged) already there (merged)."]
                for (reason, count) in summary.skipped.sorted(by: { $0.value > $1.value }) {
                    lines.append("\(count) skipped: \(reason)")
                }
                lines.append("History keeps at most \(self.config.maxItems) unpinned items (maxItems), so the oldest imported ones may have been dropped from it. Tagged items are kept in Tagged.")
                let alert = NSAlert()
                alert.messageText = "Import finished"
                alert.informativeText = lines.joined(separator: "\n")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            case .failure(let error):
                self.showError("Import failed", "\(error)")
            }
        }
    }

    @objc private func openConfig() { NSWorkspace.shared.open(AppPaths.config) }
    @objc private func openCommands() { NSWorkspace.shared.open(AppPaths.commands) }
    @objc private func openDataFolder() { NSWorkspace.shared.open(AppPaths.support) }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError("Could not change the login item", error.localizedDescription)
        }
    }

    private func openStore() throws -> Store? {
        let url = AppPaths.database
        do {
            return try Store(url: url, key: DatabaseEncryption.prepare(url))
        } catch let error as DatabaseEncryption.OpenError {
            switch error {
            case .keyMissing, .wrongKey: break
            case .keychain, .migration: throw error
            }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "The clipboard history can't be decrypted"
            alert.informativeText = "\(error)\n\nThis happens when the history was copied from another Mac or the Keychain was reset. "
                + "If you can restore the Keychain item, quit and try again. Otherwise start a new, empty history; "
                + "the unreadable file is kept in the data folder."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Start New History")
            guard alert.runModal() == .alertSecondButtonReturn else { return nil }
            let kept = try DatabaseEncryption.moveAside(url)
            NSLog("Clipsie: moved the unreadable history to \(kept.path)")
            return try Store(url: url, key: DatabaseEncryption.prepare(url))
        }
    }

    private func showError(_ message: String, _ details: String) {
        NSLog("Clipsie: \(message): \(details)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = String(details.prefix(2000))
        alert.runModal()
    }
}
