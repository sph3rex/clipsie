import Foundation
import Testing
@testable import Clipsie

struct CommandsFileTests {
    private let file = #"""
    [
      {"name": "Sort lines", "script": "text.split('\\n').sort().join('\\n')", "x": {"a": "}{"}},
      {"name": "Login", "script": "not a sequence"},
      {
        "name": "Login",
        "sequence": "item 1, tab",
        "globalShortcut": "ctrl+alt+l"
      },
      {"name": "Other", "sequence": "item 1"}
    ]

    """#

    private func entries(_ text: String) throws -> [[String: Any]] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    }

    private func names(_ text: String) throws -> [String?] {
        try entries(text).map { $0["name"] as? String }
    }

    @Test func editReplacesOnlyTheSequenceAndKeepsItsOtherFields() throws {
        let updated = try UserCommand.savingSequence(name: "Login", steps: "item 2, enter", replacing: "Login", in: file)
        let logins = try entries(updated).filter { $0["name"] as? String == "Login" }
        #expect(logins.count == 2)
        #expect(logins.first?["script"] as? String == "not a sequence")
        #expect(logins.last?["sequence"] as? String == "item 2, enter")
        #expect(logins.last?["globalShortcut"] as? String == "ctrl+alt+l")
        #expect(updated.contains(#"{"name": "Sort lines", "script": "text.split('\\n').sort().join('\\n')", "x": {"a": "}{"}},"#))
    }

    @Test func newSequenceIsAppended() throws {
        let updated = try UserCommand.savingSequence(name: "Hello", steps: #""hi", tab"#, replacing: nil, in: file)
        let last = try #require(try entries(updated).last)
        #expect(last["name"] as? String == "Hello")
        #expect(last["sequence"] as? String == #""hi", tab"#)
    }

    @Test func invalidStepsOrMissingSequenceThrow() {
        #expect(throws: (any Error).self) { try UserCommand.savingSequence(name: "X", steps: "item 1, nonsense", replacing: nil, in: file) }
        #expect(throws: (any Error).self) { try UserCommand.savingSequence(name: "X", steps: "tab", replacing: "Nope", in: file) }
        #expect(throws: (any Error).self) { try UserCommand.removingSequence(named: "Sort lines", from: file) }
    }

    @Test func deleteRemovesEntryAndCommaInEveryPosition() throws {
        #expect(try names(UserCommand.removingSequence(named: "Other", from: file)) == ["Sort lines", "Login", "Login"])
        let login = try UserCommand.removingSequence(named: "Login", from: file)
        #expect(try names(login) == ["Sort lines", "Login", "Other"])
        #expect(try entries(login)[1]["script"] as? String == "not a sequence")
        let only = "[\n  {\"name\": \"A\", \"sequence\": \"item 1\"}\n]\n"
        #expect(try UserCommand.removingSequence(named: "A", from: only) == "[\n]\n")
        let inline = #"[{"name": "A", "sequence": "tab"}, {"name": "B", "sequence": "tab"}]"#
        #expect(try UserCommand.removingSequence(named: "B", from: inline) == #"[{"name": "A", "sequence": "tab"}]"#)
        #expect(try UserCommand.removingSequence(named: "A", from: inline) == #"[{"name": "B", "sequence": "tab"}]"#)
    }

    @Test func builtInCommandsDecode() throws {
        let commands = try JSONDecoder().decode([UserCommand].self, from: Data(UserCommand.builtInCommandsJSON.utf8))
        #expect(commands.contains { $0.name == "Paste with secrets redacted" && !$0.saveOutput })
    }
}

@Suite(.serialized)
final class CommandUsageTests {
    private let suite = "ClipsieTests-\(UUID().uuidString)"
    private let commands: [UserCommand]

    init() throws {
        CommandUsage.defaults = try #require(UserDefaults(suiteName: suite))
        let json = #"[{"name": "a", "script": "1"}, {"name": "b", "script": "1"}, {"name": "c", "script": "1"}, {"name": "d", "script": "1"}]"#
        commands = try JSONDecoder().decode([UserCommand].self, from: Data(json.utf8))
    }

    deinit {
        CommandUsage.defaults.removePersistentDomain(forName: suite)
        CommandUsage.defaults = .standard
    }

    private func names(_ list: [UserCommand]) -> [String] { list.map(\.name) }

    @Test func unusedCommandsKeepTheirOrderAndUsedOnesComeFirst() {
        #expect(names(CommandUsage.ranked(commands)) == ["a", "b", "c", "d"])
        for _ in 0..<3 { CommandUsage.record("c") }
        CommandUsage.record("d")
        #expect(names(CommandUsage.ranked(commands)) == ["c", "d", "a", "b"])
        #expect(CommandUsage.last == "d")
    }

    @Test func draggedCommandsStayOnTopInTheirOrder() {
        CommandUsage.record("c")
        CommandUsage.pin(["b"], in: "commands")
        #expect(names(CommandUsage.arranged(commands, in: "commands")) == ["b", "c", "a", "d"])
        CommandUsage.pin(["d", "b"], in: "commands")
        #expect(names(CommandUsage.arranged(commands, in: "commands")) == ["d", "b", "c", "a"])
        #expect(names(CommandUsage.arranged(commands, in: "generators")) == ["c", "a", "b", "d"])
    }
}
