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
    private var lastCopy: (id: Int64, text: String, app: String?, at: Date)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        installEditMenu()
        do {
            try AppPaths.createDirectories()
            Plugins.installDefaults()
            store = try openStore()
        } catch {
            showError(L("Cannot open clipboard history"), "\(error)")
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
            showError(L("config.json is invalid — using defaults"), "\(error)")
            config = Config()
        }
        do {
            let loaded = try UserCommand.load()
            commands = loaded.commands
            if !loaded.skipped.isEmpty {
                showError(L("Automatic commands can only run JavaScript"),
                          L("These were skipped, because they use a shell \"command\": %@.\n\nAutomatic commands see everything you copy, so they run sandboxed only. Rewrite them with \"script\" (see the README), or set \"enabled\": false.",
                            loaded.skipped.map { "“\($0)”" }.joined(separator: ", ")))
            }
        } catch {
            showError(L("commands.json is invalid — no commands loaded"), "\(error)")
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
                showError(L("Invalid paste shortcut “%@” in pasteShortcutByApp", string), L("Use a form like \"ctrl+v\"."))
                return nil
            }
            return shortcut
        }
        history.commands = commands.filter { $0.type == .menu }
        history.showsPreview = config.showPreview
        history.linkPreviews = config.linkPreviews
        history.searchMode = config.searchMode
        store.setSearchMode(config.searchMode)
        history.searchProviders = config.searchProviders
        history.plugins = Plugins.load()
        if config.quickPasteModifiers.isEmpty {
            history.quickPasteModifiers = nil
        } else if let modifiers = Shortcut.modifiers(config.quickPasteModifiers), !modifiers.isEmpty {
            history.quickPasteModifiers = modifiers
        } else {
            showError(L("Invalid quickPasteModifiers “%@” in config.json", config.quickPasteModifiers),
                      L("Use modifiers like \"cmd\", \"ctrl\", \"alt\" or \"ctrl+alt\", or \"\" to turn quick paste off."))
            history.quickPasteModifiers = .command
        }
        if config.moveItemModifiers.isEmpty {
            history.moveItemModifiers = nil
        } else if let modifiers = Shortcut.modifiers(config.moveItemModifiers), !modifiers.isEmpty {
            history.moveItemModifiers = modifiers
        } else {
            showError(L("Invalid moveItemModifiers “%@” in config.json", config.moveItemModifiers),
                      L("Use modifiers like \"cmd\", \"alt\" or \"ctrl+alt\", or \"\" to turn moving items off."))
            history.moveItemModifiers = .command
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
            showError(L("Invalid %@ “%@” in config.json", key, string),
                      L("Use a shortcut with cmd or ctrl, e.g. \"cmd+shift+e\", or \"\" for none."))
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
            showError(L("Cannot register shortcut “%@”", config.historyHotkey),
                      L("It is invalid or already used by another app. Change historyHotkey in config.json."))
        }
        if !config.pastePlainHotkey.isEmpty {
            let registered = Shortcut(config.pastePlainHotkey).map {
                center.register($0, action: { [weak self] in self?.pasteClipboardAsPlainText() })
            } ?? false
            if !registered {
                showError(L("Cannot register shortcut “%@”", config.pastePlainHotkey),
                          L("It is invalid or already used by another app. Change pastePlainHotkey in config.json (\"\" disables it)."))
            }
        }
        for command in commands where command.type == .menu {
            guard let string = command.globalShortcut else { continue }
            guard let shortcut = Shortcut(string),
                  center.register(shortcut, action: { [weak self] in self?.runOnLatest(command) }) else {
                showError(L("Cannot register shortcut “%@” for “%@”", string, command.displayName), L("It is invalid or already in use."))
                continue
            }
        }
    }

    private func handleCapture(_ capture: Capture) {
        let subject = CommandSubject(capture.representations)
        let automatic = commands.filter {
            $0.type == .automatic && $0.applies(to: subject, sourceApp: capture.sourceApp)
        }
        runAutomatic(automatic[...], on: capture)
    }

    private func runAutomatic(_ remaining: ArraySlice<UserCommand>, on capture: Capture) {
        guard let command = remaining.first else {
            save(capture, mergingQuickCopies: true)
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

    private func save(_ capture: Capture, mergingQuickCopies: Bool = false) {
        guard shouldSave(capture) else { return }
        let id: Int64?
        let windowMs = Paster.bestMatch(in: config.mergeCopiesWithinMsByApp, for: capture.sourceApp) ?? 0
        if mergingQuickCopies, let last = lastCopy, let text = capture.text, last.app == capture.sourceApp,
           Date().timeIntervalSince(last.at) * 1000 < Double(windowMs), text.contains(last.text) || last.text.contains(text),
           !store.rows(ids: [last.id]).isEmpty {
            store.replace(id: last.id, with: capture)
            id = last.id
        } else {
            id = store.save(capture, maxItems: config.maxItems)
        }
        if mergingQuickCopies {
            lastCopy = id.flatMap { id in capture.text.map { (id: id, text: $0, app: capture.sourceApp, at: Date()) } }
        }
        if let id, Content.imageData(capture.representations) != nil { ocr.recognize(id) }
        history.refreshIfVisible()
    }

    private func shouldSave(_ capture: Capture) -> Bool {
        switch capture.kind {
        case .text, .richText: return config.saveText
        case .image: return config.saveImages
        case .files: return config.saveFiles
        case .other: return true
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if config.clearHistoryOnQuit { store?.clearEverything(keepingTags: config.keepTagsOnQuit) }
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

    func setSearchMode(_ mode: SearchMode) {
        do {
            try Config.set("searchMode", to: mode.rawValue)
        } catch {
            showError(L("Could not change config.json"), "\(error)")
            return
        }
        config.searchMode = mode
        store.setSearchMode(mode)
        history.searchMode = mode
    }

    func run(_ command: UserCommand, itemIDs: [Int64], target: NSRunningApplication?) {
        if let steps = command.steps {
            runSequence(command, steps: steps, itemIDs: itemIDs, target: target)
        } else if itemIDs.count > 1, command.input == .item, command.multiple == .all {
            runCommand(command, joining: itemIDs, target: target)
        } else if itemIDs.count > 1, command.input == .item {
            runCommand(command, onEach: itemIDs, target: target)
        } else {
            runCommand(command, itemID: itemIDs.first, target: target)
        }
    }

    func addSequence(name: String, steps: String) {
        do {
            try UserCommand.appendSequence(name: name, steps: steps)
        } catch {
            showError(L("Could not save the sequence"), "\(error)")
            return
        }
        reloadSettings()
    }

    private func runSequence(_ command: UserCommand, steps: [SequenceStep], itemIDs: [Int64], target: NSRunningApplication?) {
        let items = itemIDs.map { store.representations(for: $0) }
        var actions: [Paster.Action] = []
        for step in steps {
            switch step {
            case .item(let number):
                guard number <= items.count else {
                    showError(L("“%@” needs %@ selected items", command.displayName, String(command.itemsNeeded)), "")
                    return
                }
                actions.append(.paste(items[number - 1]))
            case .text(let text):
                actions.append(.paste([Representation(itemIndex: 0, type: Content.utf8Type, data: Data(text.utf8))]))
            case .key(let shortcut):
                actions.append(.key(shortcut))
            case .wait(let seconds):
                actions.append(.wait(seconds))
            }
        }
        if history.isVisible { history.hide() }
        if NSApp.isActive { NSApp.hide(nil) }
        paster.run(actions, in: target, stepDelay: Double(config.sequenceStepDelayMs) / 1000) { [weak self] problem in
            if let problem { self?.showError(L("“%@” stopped", command.displayName), problem) }
        }
    }

    private func runCommand(_ command: UserCommand, joining itemIDs: [Int64], target: NSRunningApplication?) {
        let input = itemIDs.compactMap { Content.text(store.representations(for: $0)) }
            .joined(separator: command.separator ?? config.multiPasteSeparator)
        execute(command, input: input, itemID: nil, sourceApp: nil, reps: []) { [weak self] result in
            self?.finish(command, result: result, input: input, itemID: nil, target: target)
        }
    }

    private func runCommand(_ command: UserCommand, onEach itemIDs: [Int64], target: NSRunningApplication?) {
        let inputs: [(id: Int64, text: String, reps: [Representation])] = itemIDs.compactMap { id in
            let reps = store.representations(for: id)
            let text = Content.text(reps) ?? ""
            return command.applies(to: CommandSubject(reps), sourceApp: nil) ? (id: id, text: text, reps: reps) : nil
        }
        guard !inputs.isEmpty else {
            NSSound.beep()
            return
        }
        var outputs = [CommandResult?](repeating: nil, count: inputs.count)
        var failures: [String] = []
        func step(_ index: Int) {
            guard index < inputs.count else {
                finish(command, inputs: inputs, outputs: outputs, failures: failures, target: target)
                return
            }
            let input = inputs[index]
            let started = execute(command, input: input.text, itemID: input.id, sourceApp: nil, reps: input.reps) { result in
                if result.status == 0 {
                    outputs[index] = result
                } else {
                    failures.append(result.error.isEmpty ? result.output : result.error)
                }
                step(index + 1)
            }
            if !started { step(index + 1) }
        }
        step(0)
    }

    private func finish(_ command: UserCommand, inputs: [(id: Int64, text: String, reps: [Representation])],
                        outputs: [CommandResult?], failures: [String], target: NSRunningApplication?) {
        if !failures.isEmpty {
            showError(L("Command “%@” failed for %@ of %@ items", command.displayName, String(failures.count), String(inputs.count)),
                      failures.joined(separator: "\n"))
        }
        let images = zip(inputs, outputs).compactMap { input, output in output?.image.map { (id: input.id, image: $0) } }
        if !images.isEmpty {
            switch command.output {
            case .none:
                break
            case .paste, .copy:
                let reps = images.enumerated().map { Representation(itemIndex: $0.offset, type: $0.element.image.type,
                                                                    data: $0.element.image.data) }
                guard paster.write(reps, plainTextOnly: false) else {
                    NSSound.beep()
                    return
                }
                for result in images { save(Capture(representations: [result.image], sourceApp: nil)) }
                if command.output == .paste { deliverPaste(to: target) }
            case .newItem:
                for result in images { save(Capture(representations: [result.image], sourceApp: nil)) }
            case .replace:
                for result in images {
                    store.replace(id: result.id, with: Capture(representations: [result.image], sourceApp: nil))
                    ocr.recognize(result.id)
                }
                history.refreshIfVisible()
            }
            return
        }
        let results = zip(inputs, outputs).compactMap { input, output in
            output.map { (id: input.id, output: Self.trimmed($0.output, input: input.text)) }
        }.filter { !$0.output.isEmpty }
        switch command.output {
        case .none:
            break
        case .paste, .copy:
            let joined = results.map { $0.output }.joined(separator: command.separator ?? config.multiPasteSeparator)
            guard !joined.isEmpty, paster.write(text: joined) else {
                NSSound.beep()
                return
            }
            save(Capture(text: joined, sourceApp: nil))
            if command.output == .paste { deliverPaste(to: target) }
        case .newItem:
            for result in results { save(Capture(text: result.output, sourceApp: nil)) }
        case .replace:
            for result in results { store.replace(id: result.id, with: Capture(text: result.output, sourceApp: nil)) }
            history.refreshIfVisible()
        }
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
        run(command, itemIDs: store.latestID().map { [$0] } ?? [], target: NSWorkspace.shared.frontmostApplication)
    }

    private func runCommand(_ command: UserCommand, itemID: Int64?, target: NSRunningApplication?) {
        var reps: [Representation] = []
        if command.input == .item {
            guard let itemID else { return }
            reps = store.representations(for: itemID)
        }
        let input = Content.text(reps) ?? ""
        guard command.applies(to: CommandSubject(reps), sourceApp: nil) else { return }
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
            let scriptInput = ScriptInput(text: input, itemID: itemID, sourceApp: sourceApp, types: types,
                                          image: Content.imageData(reps))
            ScriptEngine.commands.run(source, name: command.name, input: scriptInput, timeout: command.timeout) { result in
                switch result {
                case .success(.nothing):
                    completion(CommandResult(status: 0, output: "", error: ""))
                case .success(.ignore):
                    let status = command.type == .automatic ? UserCommand.ignoreExitCode : 0
                    completion(CommandResult(status: status, output: "", error: ""))
                case .success(.text(let text, _)):
                    completion(CommandResult(status: 0, output: text, error: ""))
                case .success(.image(let image)):
                    completion(CommandResult(status: 0, output: "", error: "", image: image))
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
            showError(L("Command “%@” failed (exit %@)", command.displayName, String(result.status)),
                      result.error.isEmpty ? result.output : result.error)
            return
        }
        if let image = result.image {
            let capture = Capture(representations: [image], sourceApp: nil)
            switch command.output {
            case .none:
                break
            case .paste, .copy:
                guard paster.write([image], plainTextOnly: false) else { return }
                save(capture)
                if command.output == .paste { deliverPaste(to: target) }
            case .newItem:
                save(capture)
            case .replace:
                if let itemID, command.input == .item {
                    store.replace(id: itemID, with: capture)
                    ocr.recognize(itemID)
                    history.refreshIfVisible()
                } else {
                    save(capture)
                }
            }
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
            ? NSImage(systemSymbolName: "pause.circle", accessibilityDescription: L("Clipsie (paused)"))
            : NSImage(named: "StatusIcon") ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipsie")
        image?.accessibilityDescription = monitor.isPaused ? L("Clipsie (paused)") : "Clipsie"
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menuTargetApp = NSWorkspace.shared.frontmostApplication
        menu.removeAllItems()

        let rows = store.recentRows(limit: config.menuItemCount, in: .history)
        if rows.isEmpty {
            let empty = NSMenuItem(title: L("History is empty"), action: nil, keyEquivalent: "")
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
            let taggedItem = NSMenuItem(title: L("Tagged"), action: nil, keyEquivalent: "")
            taggedItem.submenu = submenu
            menu.addItem(.separator())
            menu.addItem(taggedItem)
        }

        do {
            let latest = store.latestID()
            let subject = CommandSubject(latest.map { store.representations(for: $0) } ?? [])
            let applicable = commands.filter {
                $0.type == .menu && ($0.input == .none || latest != nil) && $0.applies(to: subject, sourceApp: nil)
            }
            if !applicable.isEmpty {
                let submenu = NSMenu()
                for command in applicable {
                    let item = NSMenuItem(title: command.displayName, action: #selector(runFromMenu(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = command.name
                    submenu.addItem(item)
                }
                let commandsItem = NSMenuItem(title: L("Commands"), action: nil, keyEquivalent: "")
                commandsItem.submenu = submenu
                menu.addItem(.separator())
                menu.addItem(commandsItem)
            }
        }

        menu.addItem(.separator())
        let hotkey = Shortcut(config.historyHotkey)?.display ?? config.historyHotkey
        addMenuItem(to: menu, L("Show History…") + "   " + hotkey, #selector(showHistoryFromMenu))
        addMenuItem(to: menu, L("Pause Capturing"), #selector(togglePause)).state = monitor.isPaused ? .on : .off
        addSubmenu(to: menu, L("Cleanup")) { submenu in
            addMenuItem(to: submenu, L("Clear History…"), #selector(clearHistory))
            addMenuItem(to: submenu, L("Remove Duplicates…"), #selector(removeDuplicates))
        }
        addSubmenu(to: menu, L("Import & Export")) { submenu in
            addMenuItem(to: submenu, L("Export as JSON…"), #selector(exportHistory))
            addMenuItem(to: submenu, isImporting ? L("Importing…") : L("Import from JSON…"), #selector(importHistory))
        }
        menu.addItem(.separator())
        addSubmenu(to: menu, L("Configuration")) { submenu in
            addMenuItem(to: submenu, L("Edit Settings…"), #selector(openConfig))
            addMenuItem(to: submenu, L("Edit Commands…"), #selector(openCommands))
            addMenuItem(to: submenu, L("Open Data Folder"), #selector(openDataFolder))
        }
        addMenuItem(to: menu, L("Reload Settings & Commands"), #selector(reloadSettings))
        addMenuItem(to: menu, L("Launch at Login"), #selector(toggleLaunchAtLogin)).state =
            SMAppService.mainApp.status == .enabled ? .on : .off
        let clearOnQuit = addMenuItem(to: menu, L("Clear on Quit"), #selector(toggleClearOnQuit))
        clearOnQuit.state = config.clearHistoryOnQuit ? .on : .off
        clearOnQuit.toolTip = config.keepTagsOnQuit.isEmpty
            ? L("When Clipsie quits, delete everything.")
            : L("When Clipsie quits, delete everything except items tagged %@.", config.keepTagsOnQuit.joined(separator: ", "))
        menu.addItem(.separator())
        addMenuItem(to: menu, L("Quit"), #selector(NSApplication.terminate(_:)), target: NSApp)
    }

    private func addSubmenu(to menu: NSMenu, _ title: String, _ fill: (NSMenu) -> Void) {
        let submenu = NSMenu()
        fill(submenu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
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
        run(command, itemIDs: store.latestID().map { [$0] } ?? [], target: menuTargetApp)
    }

    @objc private func togglePause() {
        monitor.isPaused.toggle()
        updateStatusIcon()
    }

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Clear clipboard history?")
        alert.informativeText = L("All items except pinned ones will be removed from History. Tagged items are kept in Tagged. This cannot be undone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Clear"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            store.clear(keepPinned: true)
            history.refreshIfVisible()
        }
    }

    @objc private func removeDuplicates() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Remove duplicates?")
        alert.informativeText = L("Items with exactly the same text as a newer item are deleted. The newest copy is kept and gets their pin, title and tags. Images are left alone. This cannot be undone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Remove"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.removeDuplicates { [weak self] count in
            self?.history.refreshIfVisible()
            let done = NSAlert()
            done.messageText = count == 0 ? L("No duplicates found") : L(count == 1 ? "Removed %@ duplicate" : "Removed %@ duplicates", String(count))
            NSApp.activate(ignoringOtherApps: true)
            done.runModal()
        }
    }

    @objc private func exportHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        panel.nameFieldStringValue = L("Clipboard History %@.json", day)
        panel.allowedContentTypes = [.json]
        let checkbox = NSButton(checkboxWithTitle: L("Include all formats of text items (RTF, HTML, …) — larger file. Images are always included."),
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
                alert.messageText = L("Exported %@ items", String(count))
                alert.informativeText = url.path + "\n\n" + L("The file isn't encrypted and may contain passwords or other secrets you copied.")
                alert.addButton(withTitle: L("Show in Finder"))
                alert.addButton(withTitle: L("OK"))
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            case .failure(let error):
                self?.showError(L("Export failed"), "\(error)")
            }
        }
    }

    @objc private func importHistory() {
        guard !isImporting else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = L("Choose a file made with Export as JSON…. Items you already have are merged, not duplicated.")
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
                var lines = [L("%@ added, %@ already there (merged).", String(summary.added), String(summary.merged))]
                for (reason, count) in summary.skipped.sorted(by: { $0.value > $1.value }) {
                    lines.append(L("%@ skipped: %@", String(count), reason))
                }
                lines.append(L("History keeps at most %@ unpinned items (maxItems), so the oldest imported ones may have been dropped from it. Tagged items are kept in Tagged.", String(self.config.maxItems)))
                let alert = NSAlert()
                alert.messageText = L("Import finished")
                alert.informativeText = lines.joined(separator: "\n")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            case .failure(let error):
                self.showError(L("Import failed"), "\(error)")
            }
        }
    }

    @objc private func openConfig() { NSWorkspace.shared.open(AppPaths.config) }
    @objc private func openCommands() { NSWorkspace.shared.open(AppPaths.commands) }
    @objc private func openDataFolder() { NSWorkspace.shared.open(AppPaths.support) }

    @objc private func toggleClearOnQuit() {
        do {
            try Config.set("clearHistoryOnQuit", to: !config.clearHistoryOnQuit)
            config.clearHistoryOnQuit.toggle()
        } catch {
            showError(L("Could not change config.json"), "\(error)")
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError(L("Could not change the login item"), error.localizedDescription)
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
            alert.messageText = L("The clipboard history can't be decrypted")
            alert.informativeText = "\(error)\n\n" + L("This happens when the history was copied from another Mac or the Keychain was reset. If you can restore the Keychain item, quit and try again. Otherwise start a new, empty history; the unreadable file is kept in the data folder.")
            alert.addButton(withTitle: L("Quit"))
            alert.addButton(withTitle: L("Start New History"))
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
