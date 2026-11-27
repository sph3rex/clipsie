import AppKit
import Foundation
import Testing
@testable import Clipsie

struct SequenceStepTests {
    private func describe(_ steps: [SequenceStep]) -> [String] {
        steps.map { step in
            switch step {
            case .item(let number): return "item \(number)"
            case .text(let text): return "text \(text)"
            case .key(let shortcut): return "key \(Shortcut.symbols(shortcut.modifiers))\(shortcut.keyName)"
            case .wait(let seconds): return "wait \(seconds)"
            }
        }
    }

    @Test func itemsTextKeysAndWaits() throws {
        let steps = try SequenceStep.parse(#"item 1, tab, "a, \"b\"\n", wait 200, wait 0.5s, shift+tab, b"#)
        #expect(describe(steps) == ["item 1", "key tab", "text a, \"b\"\n", "wait 0.2", "wait 0.5", "key ⇧tab", "key b"])
    }

    @Test func newLinesSeparateSteps() throws {
        #expect(describe(try SequenceStep.parse("item 1\nitem 2\n\n")) == ["item 1", "item 2"])
    }

    @Test func invalidSequencesThrow() {
        #expect(throws: (any Error).self) { try SequenceStep.parse(#""not closed"#) }
        #expect(throws: (any Error).self) { try SequenceStep.parse("item 1, frobnicate") }
        #expect(throws: (any Error).self) { try SequenceStep.parse("item 0") }
    }
}

struct ShortcutTests {
    @Test func modifiersAndKeys() {
        let shortcut = Shortcut("cmd+shift+v")
        #expect(shortcut?.keyName == "v")
        #expect(shortcut?.modifiers == NSEvent.ModifierFlags([.command, .shift]))
        #expect(Shortcut("Ctrl + Alt + O")?.display == "⌃⌥O")
        #expect(Shortcut("b")?.modifiers == NSEvent.ModifierFlags([]))
    }

    @Test func invalidShortcuts() {
        #expect(Shortcut("cmd+foo") == nil)
        #expect(Shortcut("a+b") == nil)
        #expect(Shortcut("cmd") == nil)
    }
}

struct SearchQueryTests {
    @Test func filtersAreSeparatedFromTerms() {
        let query = SearchQuery("Invoice app:Mail tag:work type:link is:pinned foo:bar")
        #expect(query.terms == ["invoice", "foo:bar"])
        #expect(query.apps == ["mail"])
        #expect(query.tags == ["work"])
        #expect(query.types == [.link])
        #expect(query.flags == [.pinned])
    }

    @Test func regexModeKeepsThePatternWhole() {
        let query = SearchQuery("a+b  c tag:x", mode: .regex)
        #expect(query.pattern == "a+b c")
        #expect(query.tags == ["x"])
    }

    @Test func fuzzyMatchToleratesTyposOnlyInLongerWords() {
        #expect(SearchQuery.fuzzyMatch("please recieve it", "receive"))
        #expect(!SearchQuery.fuzzyMatch("car", "cat"))
    }
}

struct ConfigTests {
    @Test func redactRulesAcceptWordsAndObjects() throws {
        let json = #"{"redact": ["Acme", {"match": "/PROJ-\\d+/", "with": "[ticket]"}]}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.redact.map(\.match) == ["Acme", #"/PROJ-\d+/"#])
        #expect(config.redact.map(\.with) == [nil, "[ticket]"])
    }

    @Test func missingKeysKeepTheirDefaults() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(config.activePlugins == ["calc.js"])
        #expect(config.sequencesPrefix == ">>>")
        #expect(config.repeatCommandShortcut == "cmd+r")
        #expect(config.redact.isEmpty)
    }
}
