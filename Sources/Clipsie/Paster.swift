import AppKit
import Carbon

final class Paster {
    var pasteDelay: TimeInterval = 0.05
    var pasteDelaysByApp: [String: TimeInterval] = [:]
    var pasteShortcutsByApp: [String: Shortcut] = [:]

    private static let defaultPasteShortcut = Shortcut("cmd+v")!
    var onClipboardWritten: (() -> Void)?

    @discardableResult
    func write(_ reps: [Representation], plainTextOnly: Bool) -> Bool {
        if plainTextOnly {
            guard let text = Content.text(reps) else { return false }
            return write(text: text)
        }
        var items: [NSPasteboardItem] = []
        for index in Set(reps.map(\.itemIndex)).sorted() {
            let item = NSPasteboardItem()
            for rep in reps where rep.itemIndex == index {
                item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type))
            }
            items.append(item)
        }
        return writeItems(items)
    }

    @discardableResult
    func write(text: String) -> Bool {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        return writeItems([item])
    }

    private func writeItems(_ items: [NSPasteboardItem]) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.writeObjects(items)
        onClipboardWritten?()
        return ok
    }

    func paste(into target: NSRunningApplication?) {
        guard whenReady(target, then: { self.sendKeystroke(self.pasteShortcut(for: target)) }) else {
            NSLog("Clipsie: Accessibility permission missing; content is on the clipboard but was not pasted")
            return
        }
    }

    enum Action {
        case paste([Representation])
        case key(Shortcut)
        case wait(TimeInterval)
    }

    func run(_ actions: [Action], in target: NSRunningApplication?, stepDelay: TimeInterval,
             completion: @escaping (String?) -> Void) {
        let started = whenReady(target) {
            self.runNext(actions[...], in: target, stepDelay: stepDelay, completion: completion)
        }
        if !started { completion(L("Clipsie needs the Accessibility permission to paste.")) }
    }

    private func runNext(_ remaining: ArraySlice<Action>, in target: NSRunningApplication?, stepDelay: TimeInterval,
                         completion: @escaping (String?) -> Void) {
        guard let action = remaining.first else {
            completion(nil)
            return
        }
        if let target, NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            completion(L("Another app came to the front, so the sequence stopped."))
            return
        }
        var pause = stepDelay
        switch action {
        case .paste(let reps):
            guard write(reps, plainTextOnly: false) else {
                completion(L("Could not write to the clipboard."))
                return
            }
            sendKeystroke(pasteShortcut(for: target))
        case .key(let shortcut):
            sendKeystroke(shortcut)
        case .wait(let seconds):
            pause = seconds
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pause) {
            self.runNext(remaining.dropFirst(), in: target, stepDelay: stepDelay, completion: completion)
        }
    }

    private func pasteShortcut(for target: NSRunningApplication?) -> Shortcut {
        Self.bestMatch(in: pasteShortcutsByApp, for: Self.bundleID(of: target)) ?? Self.defaultPasteShortcut
    }

    private func whenReady(_ target: NSRunningApplication?, then action: @escaping () -> Void) -> Bool {
        guard Self.isTrusted(prompt: true) else { return false }
        if let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            target.activate(options: [])
        }
        waitForTarget(target, deadline: Date().addingTimeInterval(1.0), then: action)
        return true
    }

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    private func waitForTarget(_ target: NSRunningApplication?, deadline: Date, then action: @escaping () -> Void) {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let targetReady = target == nil || frontPID == target?.processIdentifier
        if (targetReady && !Self.modifierKeysDown()) || Date() >= deadline {
            let delay = Self.bestMatch(in: pasteDelaysByApp, for: Self.bundleID(of: target)) ?? pasteDelay
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            self.waitForTarget(target, deadline: deadline, then: action)
        }
    }

    private static func bundleID(of target: NSRunningApplication?) -> String? {
        target?.bundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    static func bestMatch<T>(in byApp: [String: T], for bundleID: String?) -> T? {
        guard let bundleID else { return nil }
        return byApp.filter { bundleID.hasPrefix($0.key) }.max { $0.key.count < $1.key.count }?.value
    }

    private static func modifierKeysDown() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return !flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty
    }

    private func sendKeystroke(_ shortcut: Shortcut) {
        let isLetter = shortcut.keyName.count == 1
        let key = (isLetter ? KeyboardLayout.keyCode(for: shortcut.keyName) : nil) ?? CGKeyCode(shortcut.keyCode)
        let modifierKeys: [(NSEvent.ModifierFlags, Int, CGEventFlags)] = [
            (.control, kVK_Control, .maskControl),
            (.option, kVK_Option, .maskAlternate),
            (.shift, kVK_Shift, .maskShift),
            (.command, kVK_Command, .maskCommand),
        ].filter { shortcut.modifiers.contains($0.0) }

        var events: [(CGKeyCode, Bool, CGEventFlags)] = []
        var held: CGEventFlags = []
        for (_, code, flag) in modifierKeys {
            held.insert(flag)
            events.append((CGKeyCode(code), true, held))
        }
        events.append((key, true, held))
        events.append((key, false, held))
        for (_, code, flag) in modifierKeys.reversed() {
            held.remove(flag)
            events.append((CGKeyCode(code), false, held))
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        for (code, isDown, flags) in events {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cgSessionEventTap)
            usleep(8_000)
        }
    }
}

enum KeyboardLayout {
    static func keyCode(for character: String) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboardType = UInt32(LMGetKbdType())

        for code in 0..<128 {
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, keyboardType,
                                        OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState, chars.count, &length, &chars)
            if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length) == character {
                return CGKeyCode(code)
            }
        }
        return nil
    }
}
