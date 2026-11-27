import Foundation
import Testing
@testable import Clipsie

@Suite(.serialized)
final class BuiltInScriptTests {
    deinit {
        ScriptEngine.redactions = []
        ScriptEngine.commands.reset()
    }

    private func builtIn(_ name: String) throws -> String {
        let commands = try JSONDecoder().decode([UserCommand].self, from: Data(UserCommand.builtInCommandsJSON.utf8))
        return try #require(commands.first { $0.name == name }?.script)
    }

    private func evaluate(_ source: String, _ text: String, sourceApp: String? = nil,
                          engine: ScriptEngine = .commands) async -> Result<ScriptValue, ScriptError> {
        await withCheckedContinuation { continuation in
            let input = ScriptInput(text: text, itemID: nil, sourceApp: sourceApp, types: [])
            engine.run(source, name: "test", input: input, timeout: 5) { continuation.resume(returning: $0) }
        }
    }

    private func text(_ result: Result<ScriptValue, ScriptError>) -> String? {
        if case .success(.text(let text, _)) = result { return text }
        return nil
    }

    @Test func redactionHidesSecretsPathsAndPrompts() async throws {
        let redact = try builtIn("Paste with secrets redacted")
        let cases = [
            "key sk-proj-abcdefghijklmnopqrstuvwxyz123456 end": "key [API KEY] end",
            "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE": "AWS_ACCESS_KEY_ID=[AWS KEY]",
            "Authorization: Bearer abcdefghijklmnop1234": "Authorization: Bearer [TOKEN]",
            "postgres://admin:hunter22@db:5432/x": "postgres://admin:[PASSWORD]@db:5432/x",
            "at /Users/jane/Projects/x.swift:12": "at /Users/[user]/Projects/x.swift:12",
            #"C:\Users\Jane Doe\app"#: #"C:\Users\[user]\app"#,
            "jane@devbox:~/src$ make": "[user]@[host]:~/src$ make",
            "ping Janes-MBP.local": "ping [host]",
            "mail bob@example.com and git@github.com:org/repo.git": "mail bob@example.com and git@github.com:org/repo.git",
            "The task-runner uses sk-learn and a password field.": "The task-runner uses sk-learn and a password field.",
        ]
        for (input, expected) in cases {
            #expect(text(await evaluate(redact, input)) == expected, "\(input)")
        }
    }

    @Test func redactionAppliesTheConfiguredWords() async throws {
        let redact = try builtIn("Paste with secrets redacted")
        ScriptEngine.redactions = [["match": "Acme"], ["match": #"/PROJ-\d+/"#, "with": "[ticket]"], ["match": "C++"]]
        ScriptEngine.commands.reset()
        #expect(text(await evaluate(redact, "ACME fixed PROJ-12 in AcmeCorp with C++ not c++17"))
                == "[REDACTED] fixed [ticket] in AcmeCorp with [REDACTED] not c++17")
    }

    @Test func invalidConfiguredPatternFailsInsteadOfPastingUnredacted() async throws {
        let redact = try builtIn("Paste with secrets redacted")
        ScriptEngine.redactions = [["match": "/([/"]]
        ScriptEngine.commands.reset()
        guard case .failure = await evaluate(redact, "secret text") else {
            Issue.record("an invalid pattern must stop the command")
            return
        }
    }

    @Test func aiContextAndTerminalColours() async throws {
        #expect(text(await evaluate(try builtIn("Paste as AI context"), "ls -la", sourceApp: "com.apple.Terminal"))
                == "From Terminal:\n```\nls -la\n```")
        #expect(text(await evaluate(try builtIn("Paste without terminal colours"), "\u{1B}[1;31mERROR\u{1B}[0m done\u{1B}(B"))
                == "ERROR done")
    }

    @Test func calculatorPlugin() async throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/plugins/calc.js")
        let calc = try String(contentsOf: file, encoding: .utf8)
        let cases = ["15% of 80": "12", "5 km in miles": "3.106855961", "100 f to c": "37.77777778", "2^10": "1024"]
        for (query, expected) in cases {
            #expect(text(await evaluate(calc, query, engine: .plugins)) == expected, "\(query)")
        }
        guard case .success(.nothing) = await evaluate(calc, "hello world", engine: .plugins) else {
            Issue.record("plain text must not produce a calculator row")
            return
        }
    }
}
