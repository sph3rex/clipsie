import AppKit
import Carbon
import Quartz

@MainActor
protocol HistoryActions: AnyObject {
    func paste(itemID: Int64, plainText: Bool, target: NSRunningApplication?)
    func pasteFenced(itemID: Int64, with character: Character, target: NSRunningApplication?)
    func copy(itemID: Int64)
    func pasteText(_ text: String, target: NSRunningApplication?)
    func copyText(_ text: String)
    func pasteItems(_ ids: [Int64], target: NSRunningApplication?)
    func run(_ command: UserCommand, itemIDs: [Int64], target: NSRunningApplication?)
    func setSearchMode(_ mode: SearchMode)
    func addSequence(name: String, steps: String)
}

final class HistoryPanel: NSPanel {
    var keyEquivalentHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyEquivalentHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class HistoryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate, QLPreviewPanelDataSource {

    weak var actions: HistoryActions?
    var commands: [UserCommand] = []
    var plugins: [URL] = []
    var moveItemModifiers: NSEvent.ModifierFlags? = .command
    var quickPasteModifiers: NSEvent.ModifierFlags? = .command {
        didSet { ItemCellView.quickPastePrefix = quickPasteModifiers.map(Shortcut.symbols) ?? "" }
    }
    private var keyMonitor: Any?
    var commandsPrefix = ">" { didSet { updatePaletteHelp() } }
    var generatorsPrefix = ">>" { didSet { updatePaletteHelp() } }
    var sequencesPrefix = ">>>" { didSet { updatePaletteHelp() } }
    var commandsShortcut = Shortcut("cmd+k") { didSet { updatePaletteHelp() } }
    var generatorsShortcut = Shortcut("cmd+shift+e") { didSet { updatePaletteHelp() } }
    var searchProviders: [SearchProvider] = [] {
        didSet { rebuildSearchButtons() }
    }
    var linkPreviews = false
    var searchMode = SearchMode.exact {
        didSet { updateSearchIcon() }
    }
    var showsPreview = true {
        didSet {
            previewContainer.isHidden = !showsPreview
            split.adjustSubviews()
        }
    }

    private let store: Store
    private let tabControl = NSSegmentedControl(labels: [L("History"), L("Images"), L("Tagged")],
                                                trackingMode: .selectOne, target: nil, action: nil)
    private static let tabs: [HistoryTab] = [.history, .images, .tagged]
    private let searchIcon = NSButton()
    private let searchField = NSTextField()
    private let paletteButton = NSButton()
    private let tableView = HistoryTableView()
    private let tableScroll = NSScrollView()
    private let split = NSSplitView()
    private let previewContainer = HoverView()
    private let searchButtons = PointerStackView()
    private let previewHeader = NSView()
    private let previewHeaderLabel = NSTextField(labelWithString: "")
    private let tagBar = NSStackView()
    private var tagBarHeight: NSLayoutConstraint!
    private var tagBarNames: [String] = []
    private var isShowingHelp = false
    private var previewSearchText: String?
    private var fenceStartedAt: Date?
    private var pluginResults: [PluginResult] = []
    private var pluginGeneration = 0
    private var isShowingSheet = false
    private var editingItemID: Int64?
    private var editingOriginalText = ""
    private static let maxEditableLength = 1_000_000
    private var selectionOrder: [Int64] = []
    private var selectionAnchor: Int?
    private var selectionCursor = 0
    private var isExtendingSelection = false
    private static let fenceInterval: TimeInterval = 0.8
    private let previewScroll = NSTextView.scrollableTextView()
    private let previewImage = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var previewText: NSTextView { previewScroll.documentView as! NSTextView }

    private var targetApp: NSRunningApplication?
    private var tab = HistoryTab.history
    private var ids: [Int64] = []
    private var rowCache: [Int64: ItemRow] = [:]
    private var searchGeneration = 0
    private var previewGeneration = 0
    private var didPositionSplit = false
    private var paletteCommands: [UserCommand]?
    private var paletteItemIDs: [Int64] = []
    private var paletteSubjects: [CommandSubject] = []
    private enum PaletteKind { case commands, generators, sequences }
    private var paletteKind = PaletteKind.commands
    private static let pageSize = 100

    init(store: Store) {
        self.store = store
        let panel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
                                 styleMask: [.titled, .fullSizeContentView, .resizable],
                                 backing: .buffered, defer: true)
        panel.title = L("Clipboard History")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 300)
        panel.setFrameAutosaveName("HistoryPanelSpotlight")
        super.init(window: panel)
        panel.delegate = self
        panel.keyEquivalentHandler = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        buildUI(in: panel)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(target: NSRunningApplication?) {
        targetApp = target
        installKeyMonitor()
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(runPendingSearch), object: nil)
        searchField.stringValue = ""
        paletteCommands = nil
        pluginGeneration += 1
        pluginResults = []
        tab = .history
        tabControl.selectedSegment = 0
        apply(store.ids(matching: "", in: tab), selecting: nil)
        positionOnMouseScreen()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(searchField)
        if !didPositionSplit {
            didPositionSplit = true
            split.setPosition(split.bounds.width * 0.58, ofDividerAt: 0)
        }
    }

    func hide() {
        finishEditing(save: true)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        window?.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window?.attachedSheet == nil else { return event }
            if self.editingItemID != nil {
                guard Int(event.keyCode) == kVK_Escape else { return event }
                self.finishEditing(save: false)
                return nil
            }
            return self.handleQuickPaste(event) ? nil : event
        }
    }

    private func handleQuickPaste(_ event: NSEvent) -> Bool {
        guard let modifiers = quickPasteModifiers,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == modifiers,
              let digit = Self.digitKeyCodes.firstIndex(of: Int(event.keyCode)).map({ $0 + 1 }),
              digit <= rowCount else { return false }
        select(digit - 1)
        activateSelected(plainText: false)
        return true
    }

    private static let digitKeyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    func refreshIfVisible() {
        guard isVisible, paletteCommands == nil, editingItemID == nil, !isShowingHelp else { return }
        runSearch(selecting: selectedID)
    }

    private func buildUI(in panel: NSPanel) {
        let content = NSVisualEffectView()
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        panel.contentView = content

        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.isBordered = false
        searchIcon.imagePosition = .imageOnly
        searchIcon.refusesFirstResponder = true
        searchIcon.target = self
        searchIcon.action = #selector(showSearchModeMenu)
        updateSearchIcon()

        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 22, weight: .light)
        updatePaletteHelp()
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false
        searchField.cell?.usesSingleLineMode = true
        searchField.delegate = self

        paletteButton.image = NSImage(systemSymbolName: "bolt", accessibilityDescription: "Commands")
        paletteButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        paletteButton.isBordered = false
        paletteButton.contentTintColor = .secondaryLabelColor
        paletteButton.refusesFirstResponder = true
        paletteButton.target = self
        paletteButton.action = #selector(togglePalette)

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator

        tabControl.selectedSegment = 0
        tabControl.font = .systemFont(ofSize: NSFont.systemFontSize)
        tabControl.target = self
        tabControl.action = #selector(tabControlChanged)
        tabControl.refusesFirstResponder = true
        tabControl.toolTip = L("Switch list (Tab)")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 34
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsMultipleSelection = true
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.registerForDraggedTypes([Self.rowDragType])
        tableView.canDrag = { [weak self] in self?.isMoveGesture ?? false }
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.draggingDestinationFeedbackStyle = .regular
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        tableView.menu = contextMenu
        tableScroll.documentView = tableView
        tableScroll.drawsBackground = false
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true

        previewScroll.drawsBackground = false
        previewScroll.autohidesScrollers = true
        previewText.drawsBackground = false
        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.allowsUndo = true
        previewText.backgroundColor = .textBackgroundColor
        previewText.isAutomaticQuoteSubstitutionEnabled = false
        previewText.isAutomaticDashSubstitutionEnabled = false
        previewText.isAutomaticTextReplacementEnabled = false
        previewText.isAutomaticSpellingCorrectionEnabled = false
        previewText.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        previewText.textContainerInset = NSSize(width: 12, height: 10)
        previewText.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        previewImage.imageScaling = .scaleProportionallyDown
        previewImage.isHidden = true
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            previewImage.setContentCompressionResistancePriority(.init(1), for: orientation)
            previewImage.setContentHuggingPriority(.init(1), for: orientation)
        }

        previewHeader.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewHeader)
        tagBar.orientation = .horizontal
        tagBar.spacing = 6
        tagBar.setClippingResistancePriority(.defaultLow, for: .horizontal)
        tagBar.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(tagBar)
        tagBarHeight = tagBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tagBar.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 12),
            tagBar.trailingAnchor.constraint(lessThanOrEqualTo: previewContainer.trailingAnchor, constant: -12),
            tagBar.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -4),
            tagBarHeight,
        ])
        for view in [previewScroll, previewImage] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            previewContainer.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: previewHeader.bottomAnchor),
                view.bottomAnchor.constraint(equalTo: tagBar.topAnchor),
                view.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            ])
        }

        searchButtons.orientation = .horizontal
        searchButtons.spacing = 0
        searchButtons.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        searchButtons.isHidden = true
        previewHeaderLabel.font = .systemFont(ofSize: 11)
        previewHeaderLabel.textColor = .secondaryLabelColor
        previewHeaderLabel.lineBreakMode = .byTruncatingTail
        previewHeaderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view: NSView in [previewHeaderLabel, searchButtons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            previewHeader.addSubview(view)
            view.centerYAnchor.constraint(equalTo: previewHeader.centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            previewHeader.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 4),
            previewHeader.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewHeader.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewHeader.heightAnchor.constraint(equalToConstant: 28),
            previewHeaderLabel.leadingAnchor.constraint(equalTo: previewHeader.leadingAnchor, constant: 16),
            previewHeaderLabel.trailingAnchor.constraint(lessThanOrEqualTo: searchButtons.leadingAnchor, constant: -8),
            searchButtons.trailingAnchor.constraint(equalTo: previewHeader.trailingAnchor, constant: -10),
        ])
        previewContainer.onHoverChanged = { [weak self] _ in self?.updateSearchButtons() }

        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(tableScroll)
        split.addArrangedSubview(previewContainer)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)

        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail

        let views: [NSView] = [searchIcon, searchField, paletteButton, topSeparator, tabControl, split,
                               bottomSeparator, statusLabel]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            searchIcon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            searchIcon.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 24),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: paletteButton.leadingAnchor, constant: -10),
            paletteButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            paletteButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            paletteButton.widthAnchor.constraint(equalToConstant: 24),
            paletteButton.heightAnchor.constraint(equalToConstant: 24),
            topSeparator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            topSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabControl.topAnchor.constraint(equalTo: topSeparator.bottomAnchor, constant: 8),
            tabControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            split.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 4),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),
            bottomSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
    }

    private static var searchModes: [(mode: SearchMode, title: String, symbol: String)] {
        [
            (.exact, L("Exact"), "magnifyingglass"),
            (.fuzzy, L("Fuzzy (tolerates typos)"), "sparkle.magnifyingglass"),
            (.regex, L("Regular expression"), "text.magnifyingglass"),
        ]
    }

    private func updateSearchIcon() {
        guard let current = Self.searchModes.first(where: { $0.mode == searchMode }) else { return }
        searchIcon.image = NSImage(systemSymbolName: current.symbol, accessibilityDescription: current.title)
        searchIcon.toolTip = L("Search mode: %@ — click to change", current.title)
    }

    @objc private func showSearchModeMenu() {
        let menu = NSMenu()
        for entry in Self.searchModes {
            let item = NSMenuItem(title: entry.title, action: #selector(searchModeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.mode.rawValue
            item.state = entry.mode == searchMode ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: searchIcon.isFlipped ? searchIcon.bounds.maxY + 4 : -4), in: searchIcon)
    }

    @objc private func searchModeChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = SearchMode(rawValue: raw) else { return }
        actions?.setSearchMode(mode)
        window?.makeFirstResponder(searchField)
        if paletteCommands == nil, !isShowingHelp { runSearch(selecting: selectedID) }
        updateStatus()
    }

    private func updatePaletteHelp() {
        searchField.placeholderString = L("Search (?? help, %@ item commands, %@ generators, %@ sequences)",
                                          commandsPrefix, generatorsPrefix, sequencesPrefix)
        paletteButton.toolTip = L("Commands for the selected item: %@ or %@\nGenerators: %@ or %@\nSequences: %@", commandsPrefix,
                                  commandsShortcut?.display ?? "-", generatorsPrefix, generatorsShortcut?.display ?? "-",
                                  sequencesPrefix)
    }

    private func paletteMode(_ query: String) -> (kind: PaletteKind, filter: String)? {
        let prefixes = [(PaletteKind.sequences, sequencesPrefix), (.generators, generatorsPrefix), (.commands, commandsPrefix)]
            .filter { !$0.1.isEmpty }
            .sorted { $0.1.count > $1.1.count }
        for (kind, prefix) in prefixes where query.hasPrefix(prefix) {
            return (kind, String(query.dropFirst(prefix.count)))
        }
        return nil
    }

    private func positionOnMouseScreen() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = max(visible.minY, visible.maxY - visible.height * 0.18 - frame.height)
        window.setFrame(frame, display: false)
    }

    private func updateStatus() {
        if isShowingHelp {
            statusLabel.stringValue = L("Help — type to search · Esc closes")
            return
        }
        if editingItemID != nil {
            statusLabel.stringValue = L("Editing — ⌘S or ⌘↩ save · Esc cancel · selecting another item saves")
            return
        }
        if let paletteCommands {
            if paletteKind == .generators {
                statusLabel.stringValue = L("%@ generators — ↩ run · Esc back to history", String(paletteCommands.count))
            } else if paletteKind == .sequences {
                statusLabel.stringValue = L("%@ sequences — ↩ runs on %@ selected items · Esc back",
                                            String(paletteCommands.count), String(paletteItemIDs.count))
            } else if paletteItemIDs.isEmpty {
                statusLabel.stringValue = L("No item selected — Esc and select one, or type %@ for generators", generatorsPrefix)
            } else if paletteItemIDs.count > 1 {
                statusLabel.stringValue = L("%@ commands for %@ selected items — ↩ runs on each · %@ generators · Esc back",
                                            String(paletteCommands.count), String(paletteItemIDs.count), generatorsPrefix)
            } else {
                statusLabel.stringValue = L("%@ commands for the selected item — ↩ run · %@ generators · Esc back", String(paletteCommands.count), generatorsPrefix)
            }
            return
        }
        if selectionOrder.count > 1 {
            statusLabel.stringValue = L("%@ selected — ↩ paste all in selection order · ⌘⌫ delete all · ↑↓ back to one", String(selectionOrder.count))
            return
        }
        let hint: String
        switch tab {
        case .history:
            hint = L("↩ paste · ?? help · ⇧↩ plain · ⌘I important · ⌘L tags · ⌘E title · ⌘P pin · ⌘⌫ delete · ⇥ next list · %@ commands", commandsShortcut?.display ?? commandsPrefix)
        case .tagged:
            hint = L("↩ paste · ?? help · ⇧↩ plain · ⌘I important · ⌘L tags · ⌘E title · ⌘⌫ remove all tags · ⇥ next list · %@ commands", commandsShortcut?.display ?? commandsPrefix)
        case .images:
            hint = L("↩ paste · ?? help · ⇧↩ paste the text in the image · ⌘I important · ⌘L tags · ⌘P pin · ⌘⌫ delete · ⇥ next list")
        }
        let search = SearchQuery(searchField.stringValue, mode: searchMode)
        var notes = search.hasFilters ? [search.filterSummary] : []
        switch searchMode {
        case .exact: break
        case .fuzzy: notes.append(L("fuzzy search"))
        case .regex: notes.append(search.isValidPattern ? L("regex search") : L("invalid regular expression"))
        }
        let filters = notes.map { " · " + $0 }.joined()
        statusLabel.stringValue = L("%@ items", String(ids.count)) + filters + " — " + hint
    }

    private var rowCount: Int {
        paletteCommands?.count ?? pluginResults.count + ids.count
    }

    private func idIndex(forRow row: Int) -> Int? {
        guard paletteCommands == nil else { return nil }
        let index = row - pluginResults.count
        return index >= 0 && index < ids.count ? index : nil
    }

    private func pluginResult(at row: Int) -> PluginResult? {
        paletteCommands == nil && row >= 0 && row < pluginResults.count ? pluginResults[row] : nil
    }

    private var selectedID: Int64? {
        idIndex(forRow: tableView.selectedRow).map { ids[$0] }
    }

    private func item(at row: Int) -> ItemRow? {
        guard let index = idIndex(forRow: row) else { return nil }
        let id = ids[index]
        if let cached = rowCache[id] { return cached }
        let start = (index / Self.pageSize) * Self.pageSize
        let end = min(ids.count, start + Self.pageSize)
        for loaded in store.rows(ids: Array(ids[start..<end])) {
            rowCache[loaded.id] = loaded
        }
        return rowCache[id]
    }

    private func apply(_ newIDs: [Int64], selecting id: Int64?) {
        isShowingHelp = false
        ids = newIDs
        rowCache.removeAll()
        tableView.reloadData()
        if rowCount == 0 {
            tableView.deselectAll(nil)
            showPreview(nil)
        } else {
            select(id.flatMap { ids.firstIndex(of: $0) }.map { $0 + pluginResults.count } ?? 0)
        }
        selectionChanged()
    }

    private func runPlugins(_ query: String) {
        pluginGeneration += 1
        let generation = pluginGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plugins.isEmpty, !trimmed.isEmpty, paletteMode(query) == nil else {
            setPluginResults([])
            return
        }
        Plugins.run(plugins, query: trimmed) { [weak self] results in
            guard let self, generation == self.pluginGeneration, self.paletteCommands == nil else { return }
            self.setPluginResults(results)
        }
    }

    private func setPluginResults(_ results: [PluginResult]) {
        guard !(results.isEmpty && pluginResults.isEmpty) else { return }
        let selected = selectedID
        pluginResults = results
        tableView.reloadData()
        if rowCount == 0 {
            showPreview(nil)
        } else if !results.isEmpty {
            select(0)
        } else {
            select(selected.flatMap { ids.firstIndex(of: $0) }.map { $0 + pluginResults.count } ?? 0)
        }
        selectionChanged()
    }

    @objc private func runPendingSearch() {
        runSearch(selecting: nil)
        runPlugins(searchField.stringValue)
    }

    private func runSearch(selecting id: Int64?) {
        searchGeneration += 1
        let generation = searchGeneration
        store.ids(matching: searchField.stringValue, in: tab) { [weak self] ids in
            guard let self, generation == self.searchGeneration else { return }
            self.apply(ids, selecting: id)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        searchTextChanged()
    }

    private func searchTextChanged() {
        finishEditing(save: true)
        isShowingHelp = false
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(runPendingSearch), object: nil)
        let query = searchField.stringValue
        if handleQuickTrigger(query) { return }
        if let mode = paletteMode(query) {
            if paletteCommands == nil {
                paletteItemIDs = commandTargets
                paletteSubjects = paletteItemIDs.map { CommandSubject(store.representations(for: $0)) }
            }
            pluginGeneration += 1
            pluginResults = []
            paletteKind = mode.kind
            showPalette(filter: mode.filter)
        } else if paletteCommands != nil {
            paletteCommands = nil
            runSearch(selecting: paletteItemIDs.first)
        } else {
            perform(#selector(runPendingSearch), with: nil, afterDelay: 0.08)
        }
    }

    private static let quickTriggers: [Character: Int] = ["`": 3, "~": 3, "?": 2]

    private func handleQuickTrigger(_ query: String) -> Bool {
        guard let character = query.first, let needed = Self.quickTriggers[character],
              query.allSatisfy({ $0 == character }), paletteCommands == nil else {
            fenceStartedAt = nil
            return false
        }
        if query.count == 1 { fenceStartedAt = Date() }
        guard let started = fenceStartedAt, Date().timeIntervalSince(started) <= Self.fenceInterval else { return false }
        if query.count >= needed {
            fenceStartedAt = nil
            if character == "?" { showHelp() } else { pasteFencedSelected(with: character) }
        } else {
            perform(#selector(runPendingSearch), with: nil, afterDelay: Self.fenceInterval)
        }
        return true
    }

    @objc private func tabControlChanged() {
        switchTab(to: Self.tabs[max(0, tabControl.selectedSegment)])
    }

    private func switchTab(to newTab: HistoryTab) {
        tab = newTab
        tabControl.selectedSegment = Self.tabs.firstIndex(of: newTab) ?? 0
        window?.makeFirstResponder(searchField)
        if paletteCommands != nil {
            searchField.stringValue = ""
            paletteCommands = nil
        }
        runSearch(selecting: nil)
    }

    @objc private func togglePalette() {
        switch paletteMode(searchField.stringValue)?.kind {
        case .none: openPalette(.commands)
        case .some(.commands): openPalette(.generators)
        case .some(.generators): openPalette(sequencesPrefix.isEmpty ? nil : .sequences)
        case .some(.sequences): openPalette(nil)
        }
    }

    private func switchPalette(_ kind: PaletteKind) {
        openPalette(paletteMode(searchField.stringValue)?.kind == kind ? nil : kind)
    }

    private func openPalette(_ kind: PaletteKind?) {
        switch kind {
        case .none: searchField.stringValue = ""
        case .some(.commands): searchField.stringValue = commandsPrefix
        case .some(.generators): searchField.stringValue = generatorsPrefix
        case .some(.sequences): searchField.stringValue = sequencesPrefix
        }
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectedRange = NSRange(location: searchField.stringValue.utf16.count, length: 0)
        searchTextChanged()
    }

    private func showPalette(filter: String) {
        let terms = filter.lowercased().split(whereSeparator: \.isWhitespace)
        let matching = self.commands.filter { command in
            isInPalette(command) && terms.allSatisfy { (command.displayName + "\n" + command.name).lowercased().contains($0) }
        }
        paletteCommands = matching
        tableView.reloadData()
        if matching.isEmpty {
            tableView.deselectAll(nil)
            showPreview(nil)
        } else {
            select(0)
        }
        updateStatus()
    }

    private func isInPalette(_ command: UserCommand) -> Bool {
        switch paletteKind {
        case .sequences: return command.steps != nil
        case .generators: return command.steps == nil && command.input == .none
        case .commands: return command.steps == nil && command.input == .item && isAvailable(command, subjects: paletteSubjects)
        }
    }

    private func runSelectedPaletteCommand() {
        guard let commands = paletteCommands, tableView.selectedRow >= 0, tableView.selectedRow < commands.count else { return }
        let command = commands[tableView.selectedRow]
        run(command, itemIDs: command.input == .none && command.steps == nil ? [] : paletteItemIDs)
        if command.output != .paste && command.steps == nil {
            searchField.stringValue = ""
            searchTextChanged()
        }
    }

    @objc private func loadMultiPreview() {
        let generation = previewGeneration
        let selection = Array(selectionOrder.prefix(100))
        let count = selectionOrder.count
        DispatchQueue.global(qos: .userInitiated).async { [store, weak self] in
            let texts = selection.map { Content.text(store.representations(for: $0)) }
            DispatchQueue.main.async {
                guard let self, generation == self.previewGeneration else { return }
                self.showMultiPreview(texts, count: count)
            }
        }
    }

    private func showMultiPreview(_ texts: [String?], count: Int) {
        setPreviewHeader("")
        previewImage.image = nil
        previewImage.isHidden = true
        previewScroll.isHidden = false
        previewSearchText = nil
        updateSearchButtons()
        let content = NSMutableAttributedString(
            string: L("%@ items, pasted in the order you selected them. Items without text (images) are skipped.", String(count)) + "\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        for (index, text) in texts.enumerated() {
            let text = text ?? L("(no text — skipped)")
            content.append(NSAttributedString(string: "\(index + 1)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            content.append(NSAttributedString(string: String(text.prefix(5_000)) + "\n\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.textColor,
            ]))
        }
        previewText.textStorage?.setAttributedString(content)
        previewText.scrollToBeginningOfDocument(nil)
    }

    private func showPluginPreview(_ result: PluginResult) {
        setPreviewHeader("")
        previewImage.image = nil
        previewImage.isHidden = true
        previewScroll.isHidden = false
        previewSearchText = nil
        updateSearchButtons()
        let content = NSMutableAttributedString(string: L("From plugin “%@” · ↩ pastes · ⌘C copies", result.plugin) + "\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        content.append(NSAttributedString(string: result.title + "\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        content.append(NSAttributedString(string: result.value, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]))
        previewText.textStorage?.setAttributedString(content)
    }

    private func showCommandPreview(_ command: UserCommand) {
        setPreviewHeader("")
        let runs: String
        if let sequence = command.sequence {
            runs = L("Sequence: %@", sequence)
        } else if let script = command.script {
            runs = L("JavaScript (sandboxed): %@", script)
        } else if let file = command.scriptFile {
            runs = L("JavaScript (sandboxed): %@", "scripts/" + file)
        } else if let shell = command.command {
            runs = L("Shell, NOT sandboxed (can read your files and use the network): %@", shell)
        } else {
            runs = L("(nothing)")
        }
        var lines = [L("Runs: %@", runs), L("Output: %@", command.output.rawValue)]
        if command.input == .none {
            lines.append(L("Input: none"))
        } else {
            lines.append(paletteItemIDs.count > 1
                ? L("Input: %@ selected items, each run separately", String(paletteItemIDs.count))
                : L("Input: selected item"))
            for subject in paletteSubjects.prefix(20) {
                lines.append("")
                lines.append(String((subject.text ?? "").prefix(paletteSubjects.count > 1 ? 2_000 : 10_000)))
            }
        }
        if let shortcut = command.localShortcut { lines.insert(L("Key: %@", shortcut.display), at: 2) }
        previewImage.image = nil
        previewImage.isHidden = true
        previewScroll.isHidden = false
        previewSearchText = nil
        updateSearchButtons()
        previewText.string = lines.joined(separator: "\n")
        previewText.textColor = .textColor
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ItemCellView.identifier, owner: nil) as? ItemCellView ?? ItemCellView()
        if let paletteCommands, row < paletteCommands.count {
            cell.configure(number: row + 1, command: paletteCommands[row])
        } else if let result = pluginResult(at: row) {
            cell.configure(number: row + 1, result: result)
        } else {
            cell.configure(number: row + 1, item: item(at: row), markTags: tab != .tagged)
        }
        return cell
    }

    private static let rowDragType = NSPasteboard.PasteboardType("local.clipsie.row")
    private var droppedID: Int64?

    private var canMoveItems: Bool {
        tab == .history && paletteCommands == nil && !isShowingHelp && editingItemID == nil
    }

    private var isMoveGesture: Bool {
        guard canMoveItems, let modifiers = moveItemModifiers else { return false }
        return NSEvent.modifierFlags.intersection([.command, .shift, .option, .control]) == modifiers
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard isMoveGesture, let index = idIndex(forRow: row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(ids[index]), forType: Self.rowDragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard canMoveItems, info.draggingPasteboard.string(forType: Self.rowDragType) != nil else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard canMoveItems, let string = info.draggingPasteboard.string(forType: Self.rowDragType),
              let id = Int64(string), let from = ids.firstIndex(of: id) else { return false }
        var list = ids
        list.remove(at: from)
        var to = max(0, row - pluginResults.count)
        if from < to { to -= 1 }
        to = min(to, list.count)
        store.move(id, below: to > 0 ? list[to - 1] : nil, above: to < list.count ? list[to] : nil)
        droppedID = id
        return true
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        guard let id = droppedID else { return }
        droppedID = nil
        runSearch(selecting: id)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        HistoryRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectionChanged()
    }

    private func selectionChanged() {
        if !isExtendingSelection { selectionAnchor = nil }
        let rows = tableView.selectedRowIndexes
        let selected = rows.compactMap { idIndex(forRow: $0).map { ids[$0] } }
        let selectedSet = Set(selected)
        selectionOrder.removeAll { !selectedSet.contains($0) }
        var known = Set(selectionOrder)
        for id in selected where known.insert(id).inserted { selectionOrder.append(id) }
        if let editing = editingItemID {
            if selected == [editing] {
                updateStatus()
                return
            }
            finishEditing(save: true)
        }
        loadPreview()
        updateStatus()
    }

    private func extendSelection(by delta: Int) {
        guard rowCount > 0 else { return }
        let current = tableView.selectedRow < 0 ? 0 : tableView.selectedRow
        let anchor = selectionAnchor ?? current
        let cursor = max(0, min((selectionAnchor == nil ? current : selectionCursor) + delta, rowCount - 1))
        isExtendingSelection = true
        tableView.selectRowIndexes(IndexSet(integersIn: min(anchor, cursor)...max(anchor, cursor)), byExtendingSelection: false)
        isExtendingSelection = false
        selectionAnchor = anchor
        selectionCursor = cursor
        tableView.scrollRowToVisible(cursor)
    }

    private func select(_ row: Int) {
        guard rowCount > 0 else { return }
        let clamped = max(0, min(row, rowCount - 1))
        tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
    }

    private func moveSelection(by delta: Int) {
        select((tableView.selectedRow < 0 ? 0 : tableView.selectedRow) + delta)
    }

    private var rowsPerPage: Int {
        max(1, Int(tableScroll.contentView.bounds.height / tableView.rowHeight) - 1)
    }

    @objc private func tableDoubleClicked() {
        guard tableView.clickedRow >= 0 else { return }
        select(tableView.clickedRow)
        activateSelected(plainText: false)
    }

    private func activateSelected(plainText: Bool) {
        if paletteCommands != nil {
            runSelectedPaletteCommand()
        } else if let result = pluginResult(at: tableView.selectedRow) {
            hide()
            actions?.pasteText(result.value, target: targetApp)
        } else if selectionOrder.count > 1 {
            hide()
            actions?.pasteItems(selectionOrder, target: targetApp)
        } else {
            pasteSelected(plainText: plainText)
        }
    }

    private func loadPreview() {
        previewGeneration += 1
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(loadMultiPreview), object: nil)
        let generation = previewGeneration
        updateTagBar(selectionOrder.count <= 1 ? item(at: tableView.selectedRow) : nil)
        if let paletteCommands {
            let row = tableView.selectedRow
            if row >= 0, row < paletteCommands.count { showCommandPreview(paletteCommands[row]) } else { showPreview(nil) }
            return
        }
        if let result = pluginResult(at: tableView.selectedRow) {
            showPluginPreview(result)
            return
        }
        if selectionOrder.count > 1 {
            perform(#selector(loadMultiPreview), with: nil, afterDelay: 0.15)
            return
        }
        guard let id = selectedID else {
            showPreview(nil)
            return
        }
        store.representations(for: id) { [weak self] reps in
            guard let self, generation == self.previewGeneration else { return }
            self.showPreview(reps, recognizedText: self.store.ocrText(for: id))
        }
    }

    private static var previewFont: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }

    private func richText(for text: String, reps: [Representation], generation: Int) -> NSAttributedString {
        let paths = Content.filePaths(reps)
        if !paths.isEmpty {
            if paths.count == 1 { loadFileThumbnail(paths[0], generation: generation) }
            return RichPreview.fileDetails(paths)
        }
        let plain = NSAttributedString(string: String(text.prefix(200_000)), attributes: [
            .font: Self.previewFont, .foregroundColor: NSColor.textColor,
        ])
        if let color = RichPreview.color(in: text) {
            let result = NSMutableAttributedString()
            let attachment = NSTextAttachment()
            attachment.image = RichPreview.swatch(color, size: 96)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "\n\n" + RichPreview.colorDescription(color) + "\n\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            result.append(plain)
            return result
        }
        if let url = RichPreview.singleURL(in: text) {
            let result = NSMutableAttributedString()
            if linkPreviews, let host = url.host, let favicon = URL(string: "https://\(host)/favicon.ico").flatMap({
                Favicons.image(for: $0) { [weak self] in self?.reloadPreview(ifStill: generation) }
            }) {
                let attachment = NSTextAttachment()
                attachment.image = favicon
                attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: "  "))
            }
            let title: String
            if linkPreviews {
                switch LinkTitles.title(for: url, onLoad: { [weak self] in self?.reloadPreview(ifStill: generation) }) {
                case .some(.some(let pageTitle)): title = pageTitle
                case .some(.none): title = url.host ?? ""
                case .none: title = L("Loading title…")
                }
            } else {
                title = url.host ?? ""
            }
            let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
            result.append(NSAttributedString(string: title, attributes: [
                .font: titleFont, .link: url, .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]))
            result.append(NSAttributedString(string: "\n", attributes: [.font: titleFont]))
            result.append(NSAttributedString(string: (url.host ?? "") + "\n\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            result.append(plain)
            return result
        }
        return RichPreview.highlightedJSON(String(text.prefix(200_000)), font: Self.previewFont) ?? plain
    }

    private func reloadPreview(ifStill generation: Int) {
        guard generation == previewGeneration, editingItemID == nil else { return }
        loadPreview()
    }

    private func loadFileThumbnail(_ path: String, generation: Int) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let width = max(80, previewScroll.contentSize.width - 30)
        RichPreview.thumbnail(for: path, size: CGSize(width: width, height: 260)) { [weak self] image in
            guard let self, let image, generation == self.previewGeneration, self.editingItemID == nil else { return }
            let attachment = NSTextAttachment()
            attachment.image = image
            let scale = min(1, width / max(image.size.width, 1), 260 / max(image.size.height, 1))
            attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
            let thumbnail = NSMutableAttributedString(attachment: attachment)
            thumbnail.append(NSAttributedString(string: "\n\n"))
            self.previewText.textStorage?.insert(thumbnail, at: 0)
        }
    }

    private func showPreview(_ reps: [Representation]?, recognizedText: String? = nil) {
        previewSearchText = reps.flatMap { Content.filePaths($0).isEmpty ? Content.plainText($0) : nil } ?? recognizedText
        updateSearchButtons()
        guard let reps, !reps.isEmpty else {
            setPreviewHeader("")
            previewText.string = ""
            previewImage.image = nil
            previewImage.isHidden = true
            previewScroll.isHidden = false
            return
        }
        var types: [String] = []
        for rep in reps where !types.contains(rep.type) { types.append(rep.type) }
        let size = ByteCountFormatter.string(fromByteCount: Int64(reps.reduce(0) { $0 + $1.data.count }), countStyle: .file)
        setPreviewHeader(Content.typeSummary(reps) + " · " + size, toolTip: types.joined(separator: "\n"))
        let text = Content.text(reps)
        let image = Content.imageData(reps).flatMap { NSImage(data: $0) }
        if text == nil, recognizedText == nil, let image {
            previewImage.image = image
            previewImage.isHidden = false
            previewScroll.isHidden = true
            return
        }
        previewImage.image = nil
        previewImage.isHidden = true
        previewScroll.isHidden = false
        let content = NSMutableAttributedString()
        if let image {
            let attachment = NSTextAttachment()
            attachment.image = image
            let maxWidth = max(80, previewScroll.contentSize.width - 30)
            let size = image.size
            let scale = min(1, maxWidth / max(size.width, 1), 260 / max(size.height, 1))
            attachment.bounds = NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
            content.append(NSAttributedString(attachment: attachment))
            content.append(NSAttributedString(string: "\n\n"))
        }
        if text == nil, recognizedText != nil {
            content.append(NSAttributedString(string: L("Text in the image · ⇧↩ pastes it") + "\n\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        if let text {
            content.append(richText(for: text, reps: reps, generation: previewGeneration))
        } else {
            content.append(NSAttributedString(string: recognizedText.map { String($0.prefix(200_000)) } ?? L("(no text)"),
                                              attributes: [.font: Self.previewFont, .foregroundColor: NSColor.textColor]))
        }
        previewText.textStorage?.setAttributedString(content)
        previewText.scrollToBeginningOfDocument(nil)
    }

    private func showHelp() {
        searchGeneration += 1
        pluginGeneration += 1
        ids = []
        rowCache.removeAll()
        pluginResults = []
        tableView.reloadData()
        selectionChanged()
        isShowingHelp = true
        previewText.textStorage?.setAttributedString(Help.text(
            commands: commandsShortcut.map { L("%@ or %@", $0.display, commandsPrefix) } ?? commandsPrefix,
            generators: generatorsShortcut.map { L("%@ or %@", $0.display, generatorsPrefix) } ?? generatorsPrefix,
            sequences: sequencesPrefix,
            quickPaste: quickPasteModifiers.map(Shortcut.symbols),
            move: moveItemModifiers.map(Shortcut.symbols)))
        previewText.scrollToBeginningOfDocument(nil)
        updateStatus()
    }

    private func updateTagBar(_ row: ItemRow?) {
        tagBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tagBarNames = row?.tags ?? []
        tagBarHeight.constant = row == nil ? 0 : 28
        guard let row else { return }
        for (index, name) in row.tags.enumerated() {
            let chip = NSButton(title: name, target: self, action: #selector(tagChipClicked(_:)))
            chip.bezelStyle = .inline
            chip.controlSize = .small
            chip.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            chip.tag = index
            chip.refusesFirstResponder = true
            chip.toolTip = L("Show items tagged “%@” (tag:%@)", name, name)
            tagBar.addArrangedSubview(chip)
        }
        let edit = NSButton(title: row.tags.isEmpty ? L("Add tag") : "",
                            image: NSImage(systemSymbolName: "tag", accessibilityDescription: "Tags") ?? NSImage(),
                            target: self, action: #selector(editTagsClicked))
        edit.isBordered = false
        edit.imagePosition = .imageLeading
        edit.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        edit.contentTintColor = .secondaryLabelColor
        edit.refusesFirstResponder = true
        edit.toolTip = L("Add or remove tags (⌘L)")
        tagBar.addArrangedSubview(edit)
    }

    @objc private func tagChipClicked(_ sender: NSButton) {
        guard sender.tag < tagBarNames.count else { return }
        searchField.stringValue = "tag:" + tagBarNames[sender.tag]
        window?.makeFirstResponder(searchField)
        searchTextChanged()
    }

    @objc private func editTagsClicked() { editTagsSelected() }

    private func setPreviewHeader(_ text: String, toolTip: String? = nil) {
        previewHeaderLabel.stringValue = text
        previewHeaderLabel.toolTip = toolTip
    }

    private func rebuildSearchButtons() {
        searchButtons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, provider) in searchProviders.enumerated() {
            var image = provider.iconURL.flatMap { url in
                Favicons.image(for: url) { [weak self] in self?.rebuildSearchButtons() }
            }.map { favicon -> NSImage in
                let copy = favicon.copy() as! NSImage
                copy.size = NSSize(width: 16, height: 16)
                return copy
            }
            if image == nil {
                image = NSImage(systemSymbolName: provider.symbol ?? "magnifyingglass", accessibilityDescription: provider.name)
                    ?? NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: provider.name)
            }
            let button = PointerButton(image: image ?? NSImage(), target: self, action: #selector(searchButtonClicked(_:)))
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = L("Search with %@", provider.name)
            button.tag = index
            button.refusesFirstResponder = true
            button.imagePosition = .imageOnly
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            searchButtons.addArrangedSubview(button)
        }
        updateSearchButtons()
    }

    private func updateSearchButtons() {
        let hasText = !(previewSearchText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        searchButtons.isHidden = !(previewContainer.isHovered && hasText && !searchProviders.isEmpty)
    }

    @objc private func searchButtonClicked(_ sender: NSButton) {
        guard sender.tag < searchProviders.count, let text = previewSearchText,
              let url = searchProviders[sender.tag].url(for: text) else {
            NSSound.beep()
            return
        }
        dismiss()
        NSWorkspace.shared.open(url)
    }

    private func pasteSelected(plainText: Bool) {
        guard let id = selectedID else { return }
        hide()
        actions?.paste(itemID: id, plainText: plainText, target: targetApp)
    }

    private func pasteFencedSelected(with character: Character) {
        guard let id = selectedID else {
            NSSound.beep()
            return
        }
        hide()
        actions?.pasteFenced(itemID: id, with: character, target: targetApp)
    }

    private func copySelected() {
        if let result = pluginResult(at: tableView.selectedRow) {
            actions?.copyText(result.value)
            return
        }
        guard let id = selectedID else { return }
        actions?.copy(itemID: id)
        runSearch(selecting: id)
    }

    private func togglePinSelected() {
        guard let id = selectedID, let row = item(at: tableView.selectedRow) else { return }
        store.setPinned(id, !row.pinned)
        runSearch(selecting: id)
    }

    private func toggleImportantSelected() {
        guard let id = selectedID, let row = item(at: tableView.selectedRow) else { return }
        let others = row.tags.filter { $0.caseInsensitiveCompare(Store.importantTag) != .orderedSame }
        store.setTags(id, row.important ? others : row.tags + [Store.importantTag])
        runSearch(selecting: id)
    }

    private func editTagsSelected() {
        guard let window, paletteCommands == nil, let id = selectedID, let row = item(at: tableView.selectedRow) else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = L("Tags")
        alert.informativeText = L("Separate tags with spaces or commas. Tagged items stay in the Tagged list after they leave History. Search them with tag:name.\n\nExisting tags: %@",
                                  store.allTags().joined(separator: ", "))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = row.tags.joined(separator: " ")
        field.placeholderString = L("e.g. important work")
        alert.accessoryView = field
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        isShowingSheet = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isShowingSheet = false
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(self.searchField)
            guard response == .alertFirstButtonReturn else { return }
            self.store.setTags(id, field.stringValue.split { $0 == "," || $0.isWhitespace }.map(String.init))
            self.runSearch(selecting: id)
        }
    }

    private func editTitleSelected() {
        guard let window, let id = selectedID, let row = item(at: tableView.selectedRow) else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = row.title == nil ? L("Add a title") : L("Edit title")
        alert.informativeText = L("Shown in the lists and the menu bar instead of the content. Pasting still pastes the content. Leave empty to remove it.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = row.title ?? ""
        field.placeholderString = String(row.preview.prefix(60))
        alert.accessoryView = field
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        isShowingSheet = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isShowingSheet = false
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(self.searchField)
            guard response == .alertFirstButtonReturn else { return }
            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.store.setTitle(id, title.isEmpty ? nil : title)
            if !title.isEmpty && row.tags.isEmpty { self.store.setTags(id, [Store.importantTag]) }
            self.runSearch(selecting: id)
        }
    }

    private func editTextSelected() {
        guard paletteCommands == nil, selectionOrder.count <= 1, let id = selectedID,
              let row = item(at: tableView.selectedRow), row.kind == .text || row.kind == .richText else {
            NSSound.beep()
            return
        }
        let reps = store.representations(for: id)
        guard let text = Content.plainText(reps), Content.imageData(reps) == nil,
              text.utf16.count <= Self.maxEditableLength else {
            NSSound.beep()
            return
        }
        guard row.kind == .richText, let window else {
            beginEditing(id, text: text)
            return
        }
        let alert = NSAlert()
        alert.messageText = L("Edit as plain text?")
        alert.informativeText = L("This item has formatting (%@). Saving your changes replaces it with plain text, so the formatting is lost. Cancelling the edit (Esc) keeps it.", Content.typeSummary(reps))
        alert.addButton(withTitle: L("Edit as Plain Text"))
        alert.addButton(withTitle: L("Cancel"))
        isShowingSheet = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isShowingSheet = false
            window.makeKeyAndOrderFront(nil)
            if response == .alertFirstButtonReturn, self.selectedID == id {
                self.beginEditing(id, text: text)
            } else {
                window.makeFirstResponder(self.searchField)
            }
        }
    }

    private func beginEditing(_ id: Int64, text: String) {
        editingItemID = id
        editingOriginalText = text
        previewImage.image = nil
        previewImage.isHidden = true
        previewScroll.isHidden = false
        previewSearchText = nil
        updateSearchButtons()
        setPreviewHeader(L("Editing as plain text"))
        previewText.isRichText = false
        previewText.string = text
        previewText.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        previewText.textColor = .textColor
        previewText.drawsBackground = true
        previewText.isEditable = true
        previewText.undoManager?.removeAllActions()
        previewText.setSelectedRange(NSRange(location: 0, length: 0))
        previewText.scrollToBeginningOfDocument(nil)
        window?.makeFirstResponder(previewText)
        updateStatus()
    }

    private func finishEditing(save: Bool) {
        guard let id = editingItemID else { return }
        editingItemID = nil
        let text = previewText.string
        previewText.isEditable = false
        previewText.isRichText = true
        previewText.drawsBackground = false
        previewText.undoManager?.removeAllActions()
        if window?.firstResponder === previewText { window?.makeFirstResponder(searchField) }
        if save && text != editingOriginalText {
            if text.isEmpty {
                NSSound.beep()
            } else {
                store.replace(id: id, with: Capture(text: text, sourceApp: nil), moveToTop: false)
            }
        }
        rowCache[id] = nil
        runSearch(selecting: selectedID ?? id)
    }

    private func deleteSelected() {
        let rows = IndexSet(tableView.selectedRowIndexes.filter { idIndex(forRow: $0) != nil })
        guard let first = rows.first else { return }
        for row in rows.reversed() {
            guard let index = idIndex(forRow: row) else { continue }
            let id = ids[index]
            store.remove(id, from: tab)
            ids.remove(at: index)
            rowCache[id] = nil
        }
        tableView.removeRows(at: rows, withAnimation: [])
        if rowCount == 0 { showPreview(nil) } else { select(first) }
        selectionChanged()
        updateStatus()
    }

    private func run(_ command: UserCommand, itemIDs: [Int64]) {
        if command.output == .paste || command.steps != nil { hide() }
        actions?.run(command, itemIDs: itemIDs, target: targetApp)
    }

    private func dismiss() {
        hide()
        NSApp.hide(nil)
    }

    private var commandTargets: [Int64] {
        selectionOrder.count > 1 ? selectionOrder : (selectedID.map { [$0] } ?? [])
    }

    private func applicableCommands(for ids: [Int64]) -> [UserCommand] {
        let subjects = ids.map { CommandSubject(store.representations(for: $0)) }
        return commands.filter { $0.steps == nil && $0.input == .item && isAvailable($0, subjects: subjects) }
    }

    private func isAvailable(_ command: UserCommand, subjects: [CommandSubject]) -> Bool {
        if command.steps != nil { return true }
        guard !subjects.isEmpty else { return false }
        return subjects.allSatisfy { command.applies(to: $0, sourceApp: nil) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUpAndModifySelection(_:)):
            extendSelection(by: -1)
        case #selector(NSResponder.moveDownAndModifySelection(_:)):
            extendSelection(by: 1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            moveSelection(by: -rowsPerPage)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            moveSelection(by: rowsPerPage)
        case #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            select(0)
        case #selector(NSResponder.scrollToEndOfDocument(_:)):
            select(rowCount - 1)
        case #selector(NSResponder.insertNewline(_:)):
            activateSelected(plainText: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty {
                dismiss()
            } else {
                searchField.stringValue = ""
                searchTextChanged()
            }
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):
            deleteSelected()
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            let index = Self.tabs.firstIndex(of: tab) ?? 0
            let step = selector == #selector(NSResponder.insertBacktab(_:)) ? Self.tabs.count - 1 : 1
            switchTab(to: Self.tabs[(index + step) % Self.tabs.count])
        default:
            return false
        }
        return true
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if editingItemID != nil {
            guard modifiers == .command, ["s", "\r"].contains(event.charactersIgnoringModifiers ?? "") else { return false }
            finishEditing(save: true)
            return true
        }
        let matching = commands.filter { $0.localShortcut?.matches(event) == true }
        if let generator = matching.first(where: { $0.input == .none }) {
            run(generator, itemIDs: [])
            return true
        }
        let targets = commandTargets
        if !targets.isEmpty, !matching.isEmpty {
            let subjects = targets.map { CommandSubject(store.representations(for: $0)) }
            if let command = matching.first(where: { isAvailable($0, subjects: subjects) }) {
                run(command, itemIDs: targets)
                return true
            }
        }
        if commandsShortcut?.matches(event) == true {
            switchPalette(.commands)
            return true
        }
        if generatorsShortcut?.matches(event) == true {
            switchPalette(.generators)
            return true
        }
        guard modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "c":
            let fieldSelection = searchField.currentEditor()?.selectedRange.length ?? 0
            let previewSelected = window?.firstResponder === previewText && previewText.selectedRange().length > 0
            if fieldSelection > 0 || previewSelected { return false }
            copySelected()
        case "i":
            toggleImportantSelected()
        case "p":
            togglePinSelected()
        case "e":
            editTitleSelected()
        case "l":
            editTagsSelected()
        case "y":
            toggleQuickLook()
        case "\r":
            editTextSelected()
        case "w":
            dismiss()
        default:
            return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isShowingSheet, window?.attachedSheet == nil, quickLookURLs.isEmpty else { return }
        hide()
    }

    private var quickLookURLs: [URL] = []

    private func toggleQuickLook() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        let paths = selectedID.map { Content.filePaths(store.representations(for: $0)) } ?? []
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else {
            NSSound.beep()
            return
        }
        quickLookURLs = existing.map { URL(fileURLWithPath: $0) }
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        !quickLookURLs.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        quickLookURLs = []
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            if NSApp.isActive {
                self.window?.makeKeyAndOrderFront(nil)
                self.window?.makeFirstResponder(self.searchField)
            } else {
                self.hide()
            }
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookURLs[index] as NSURL
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard let index = idIndex(forRow: row) else { return }
        if !tableView.selectedRowIndexes.contains(row) { select(row) }
        let id = ids[index]
        if selectionOrder.count > 1 {
            menu.addItem(menuItem(L("Paste %@ Items", String(selectionOrder.count)), #selector(menuPasteAll)))
            menu.addItem(menuItem(L("Delete %@ Items from This List", String(selectionOrder.count)), #selector(menuDelete)))
            menu.addItem(menuItem(L("Save as Sequence…"), #selector(menuSaveSequence)))
            addCommandItems(to: menu, for: selectionOrder)
            return
        }
        let pinned = item(at: row)?.pinned ?? false
        let important = item(at: row)?.important ?? false

        menu.addItem(menuItem(L("Paste"), #selector(menuPaste)))
        menu.addItem(menuItem(L("Paste as Plain Text"), #selector(menuPastePlain)))
        menu.addItem(menuItem(L("Copy"), #selector(menuCopy)))
        menu.addItem(menuItem(important ? L("Remove Tag “important”") : L("Add Tag “important”"), #selector(menuToggleImportant)))
        menu.addItem(menuItem(L("Tags…"), #selector(menuEditTags)))
        menu.addItem(menuItem(item(at: row)?.title == nil ? L("Add Title…") : L("Edit Title…"), #selector(menuEditTitle)))
        if let kind = item(at: row)?.kind, kind == .text || kind == .richText {
            menu.addItem(menuItem(L("Edit Text"), #selector(menuEditText)))
        }
        switch tab {
        case .history, .images:
            menu.addItem(menuItem(pinned ? L("Unpin") : L("Pin"), #selector(menuTogglePin)))
            menu.addItem(menuItem(L("Delete from History"), #selector(menuDelete)))
        case .tagged:
            menu.addItem(menuItem(L("Remove All Tags"), #selector(menuDelete)))
        }

        addCommandItems(to: menu, for: [id])
    }

    private func addCommandItems(to menu: NSMenu, for ids: [Int64]) {
        let applicable = applicableCommands(for: ids)
        let sequences = commands.filter { $0.steps != nil }
        guard !applicable.isEmpty || !sequences.isEmpty else { return }
        menu.addItem(.separator())
        for command in applicable { menu.addItem(commandMenuItem(command)) }
        guard !sequences.isEmpty else { return }
        let submenu = NSMenu()
        for command in sequences { submenu.addItem(commandMenuItem(command)) }
        let item = NSMenuItem(title: L("Sequences"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private func commandMenuItem(_ command: UserCommand) -> NSMenuItem {
        let item = menuItem(command.displayName, #selector(menuRunCommand(_:)))
        item.representedObject = command.name
        if let shortcut = command.localShortcut { item.title += "   " + shortcut.display }
        return item
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func menuPaste() { pasteSelected(plainText: false) }
    @objc private func menuPasteAll() { activateSelected(plainText: false) }
    @objc private func menuPastePlain() { pasteSelected(plainText: true) }
    @objc private func menuCopy() { copySelected() }
    @objc private func menuTogglePin() { togglePinSelected() }
    @objc private func menuDelete() { deleteSelected() }
    @objc private func menuToggleImportant() { toggleImportantSelected() }
    @objc private func menuEditTitle() { editTitleSelected() }
    @objc private func menuEditText() { editTextSelected() }
    @objc private func menuEditTags() { editTagsSelected() }

    @objc private func menuSaveSequence() {
        guard let window, selectionOrder.count > 1 else { return }
        let alert = NSAlert()
        alert.messageText = L("Save as Sequence")
        alert.informativeText = L("A sequence pastes the selected items one after another, with keys and pauses in between. item 1…n are the items selected when you run it, in the order you selected them. Steps: item 1, \"text\", wait 200 (ms), or a key like tab, enter, shift+tab or cmd+a.")
        let name = NSTextField(frame: NSRect(x: 0, y: 34, width: 380, height: 24))
        name.placeholderString = L("Name, e.g. Fill login form")
        let steps = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        steps.stringValue = (1...selectionOrder.count).map { "item \($0)" }.joined(separator: ", tab, ")
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 58))
        fields.addSubview(name)
        fields.addSubview(steps)
        name.nextKeyView = steps
        alert.accessoryView = fields
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = name
        isShowingSheet = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isShowingSheet = false
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(self.searchField)
            let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !title.isEmpty else { return }
            self.actions?.addSequence(name: title, steps: steps.stringValue)
        }
    }

    @objc private func menuRunCommand(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let command = commands.first(where: { $0.name == name }) else { return }
        run(command, itemIDs: command.input == .none ? [] : commandTargets)
    }
}

final class PointerButton: NSButton {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class PointerStackView: NSStackView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {}
}

final class HoverView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private(set) var isHovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHoverChanged?(false)
    }
}

final class HistoryTableView: NSTableView {
    var canDrag: () -> Bool = { true }

    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        canDrag() && super.canDragRows(with: rowIndexes, at: mouseDownPoint)
    }
}

final class HistoryRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

final class ItemCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ItemCell")

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static var appIcons: [String: NSImage?] = [:]

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let marksLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    static var quickPastePrefix = "⌘"
    private let shortcutLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        textField = titleLabel
        imageView = iconView

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 4
        iconView.layer?.masksToBounds = true
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        marksLabel.alignment = .right
        marksLabel.font = .systemFont(ofSize: 11)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.alignment = .right
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutLabel.font = .systemFont(ofSize: 11)
        shortcutLabel.alignment = .right

        for view: NSView in [iconView, titleLabel, marksLabel, detailLabel, shortcutLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: marksLabel.leadingAnchor, constant: -8),
            marksLabel.widthAnchor.constraint(equalToConstant: 48),
            marksLabel.trailingAnchor.constraint(equalTo: detailLabel.leadingAnchor, constant: -6),
            detailLabel.widthAnchor.constraint(equalToConstant: 84),
            detailLabel.trailingAnchor.constraint(equalTo: shortcutLabel.leadingAnchor, constant: -6),
            shortcutLabel.widthAnchor.constraint(equalToConstant: 28),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        let primary: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        titleLabel.textColor = primary
        marksLabel.textColor = selected ? primary.withAlphaComponent(0.8) : .secondaryLabelColor
        detailLabel.textColor = selected ? primary.withAlphaComponent(0.8) : .secondaryLabelColor
        shortcutLabel.textColor = selected ? primary.withAlphaComponent(0.6) : .tertiaryLabelColor
        iconView.contentTintColor = selected ? primary : .secondaryLabelColor
    }

    func configure(number: Int, item: ItemRow?, markTags: Bool) {
        shortcutLabel.stringValue = number <= 9 ? Self.quickPastePrefix + "\(number)" : ""
        guard let item else {
            iconView.image = nil
            titleLabel.stringValue = ""
            marksLabel.stringValue = ""
            detailLabel.stringValue = ""
            return
        }
        if item.kind == .text || item.kind == .richText, let color = RichPreview.color(in: item.preview) {
            iconView.image = RichPreview.swatch(color, size: 20)
        } else {
            iconView.image = Self.icon(for: item)
        }
        titleLabel.stringValue = item.title ?? Self.title(for: item)
        titleLabel.font = .systemFont(ofSize: 13, weight: item.title == nil ? .regular : .semibold)
        toolTip = item.title == nil ? nil : Self.title(for: item)
        let otherTags = item.tags.count > (item.important ? 1 : 0)
        marksLabel.stringValue = (item.important ? "★" : "") + (markTags && otherTags ? "🏷" : "") + (item.pinned ? "📌" : "")
        detailLabel.stringValue = Self.dateFormatter.localizedString(for: item.usedAt, relativeTo: Date())
    }

    func configure(number: Int, result: PluginResult) {
        shortcutLabel.stringValue = number <= 9 ? Self.quickPastePrefix + "\(number)" : ""
        iconView.image = NSImage(systemSymbolName: "function", accessibilityDescription: nil)
        marksLabel.stringValue = ""
        titleLabel.stringValue = result.title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.stringValue = result.plugin
        toolTip = nil
    }

    func configure(number: Int, command: UserCommand) {
        titleLabel.font = .systemFont(ofSize: 13)
        shortcutLabel.stringValue = number <= 9 ? Self.quickPastePrefix + "\(number)" : ""
        iconView.image = NSImage(systemSymbolName: command.input == .none ? "sparkles" : "bolt",
                                 accessibilityDescription: nil)
        marksLabel.stringValue = command.usesShell ? "⚠︎" : ""
        toolTip = command.usesShell ? L("Shell command: not sandboxed") : nil
        titleLabel.stringValue = command.displayName
        detailLabel.stringValue = command.localShortcut?.display ?? command.output.rawValue
    }

    private static func icon(for item: ItemRow) -> NSImage? {
        if let data = item.thumbnail, let image = NSImage(data: data) { return image }
        if let bundleID = item.sourceApp, let icon = appIcon(bundleID) { return icon }
        let symbol: String
        switch item.kind {
        case .image: symbol = "photo"
        case .files: symbol = "doc"
        default: symbol = "doc.text"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    static func appIcon(_ bundleID: String) -> NSImage? {
        if let cached = appIcons[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        appIcons[bundleID] = .some(icon)
        return icon
    }

    private static func title(for item: ItemRow) -> String {
        for prefix in ["🖼 ", "📁 "] where item.preview.hasPrefix(prefix) {
            return String(item.preview.dropFirst(prefix.count))
        }
        return item.preview
    }
}
