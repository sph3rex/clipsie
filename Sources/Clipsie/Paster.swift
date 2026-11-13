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
        guard Self.isTrusted(prompt: true) else {
            NSLog("Clipsie: Accessibility permission missing; content is on the clipboard but was not pasted")
            return
        }
        if let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            target.activate(options: [])
        }
        waitForTarget(target, deadline: Date().addingTimeInterval(1.0))
    }

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    private func waitForTarget(_ target: NSRunningApplication?, deadline: Date) {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let targetReady = target == nil || frontPID == target?.processIdentifier
        if (targetReady && !Self.modifierKeysDown()) || Date() >= deadline {
            let bundleID = Self.bundleID(of: target)
            let delay = Self.bestMatch(in: pasteDelaysByApp, for: bundleID) ?? pasteDelay
            let shortcut = Self.bestMatch(in: pasteShortcutsByApp, for: bundleID) ?? Self.defaultPasteShortcut
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.sendKeystroke(shortcut)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            self.waitForTarget(target, deadline: deadline)
        }
    }

    private static func bundleID(of target: NSRunningApplication?) -> String? {
        target?.bundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private static func bestMatch<T>(in byApp: [String: T], for bundleID: String?) -> T? {
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
