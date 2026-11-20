import AppKit

enum SequenceStep {
    case item(Int)
    case text(String)
    case key(Shortcut)
    case wait(TimeInterval)

    static func parse(_ source: String) throws -> [SequenceStep] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in source {
            if inQuotes {
                current.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inQuotes = false
                }
            } else if character == "\"" {
                inQuotes = true
                current.append(character)
            } else if character == "," || character == "\n" {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        guard !inQuotes else { throw ScriptError(message: L("A quote in the sequence isn't closed.")) }
        parts.append(current)
        return try parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map(step)
    }

    private static func step(_ part: String) throws -> SequenceStep {
        if part.hasPrefix("\"") {
            let inner = part.dropFirst().dropLast()
            var text = ""
            var escaped = false
            for character in inner {
                if escaped {
                    text.append(["n": "\n", "t": "\t"][character] ?? character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else {
                    text.append(character)
                }
            }
            return .text(text)
        }
        let lower = part.lowercased()
        if lower.hasPrefix("item"), let number = Int(lower.dropFirst(4).trimmingCharacters(in: .whitespaces)), number >= 1 {
            return .item(number)
        }
        if lower.hasPrefix("wait") {
            let amount = lower.dropFirst(4).replacingOccurrences(of: " ", with: "")
            if amount.hasSuffix("ms"), let value = Double(amount.dropLast(2)) { return .wait(value / 1000) }
            if amount.hasSuffix("s"), let value = Double(amount.dropLast()) { return .wait(value) }
            if let value = Double(amount) { return .wait(value / 1000) }
        }
        if let shortcut = Shortcut(part) { return .key(shortcut) }
        throw ScriptError(message: L("Unknown step “%@”. Use item 1, \"text\", wait 200, or a key like tab, enter or cmd+a.", part))
    }
}

struct CommandSubject {
    let text: String?
    let types: Set<SearchQuery.ContentType>

    init(_ reps: [Representation]) {
        text = Content.text(reps)
        var types: Set<SearchQuery.ContentType> = []
        if Content.imageData(reps) != nil { types.insert(.image) }
        if !Content.filePaths(reps).isEmpty {
            types.insert(.file)
        } else if let plain = Content.plainText(reps) {
            types.insert(.text)
            if Content.hasRichText(reps) { types.insert(.rich) }
            if RichPreview.singleURL(in: plain) != nil { types.insert(.link) }
            if RichPreview.color(in: plain) != nil { types.insert(.color) }
        }
        if types.isEmpty { types.insert(.other) }
        self.types = types
    }
}

struct UserCommand: Decodable {
    enum Multiple: String, Decodable { case each, all }
    enum Kind: String, Decodable { case menu, automatic }
    enum Output: String, Decodable { case none, paste, copy, newItem, replace }
    enum Input: String, Decodable { case item, none }

    static let ignoreExitCode: Int32 = 10

    let name: String
    let type: Kind
    let enabled: Bool
    let command: String?
    let script: String?
    let scriptFile: String?
    let input: Input
    let match: String?
    let sourceApps: [String]?
    let shortcut: String?
    let globalShortcut: String?
    let output: Output
    let ignore: Bool
    let timeout: Double
    let sequence: String?
    let steps: [SequenceStep]?
    let multiple: Multiple
    let separator: String?
    let saveOutput: Bool
    let types: Set<SearchQuery.ContentType>?
    private let regex: NSRegularExpression?

    private enum CodingKeys: String, CodingKey {
        case name, type, enabled, command, script, scriptFile, input, match, sourceApps, shortcut, globalShortcut, output
        case ignore, timeout, sequence, multiple, separator, types, saveOutput
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decodeIfPresent(Kind.self, forKey: .type) ?? .menu
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        command = try c.decodeIfPresent(String.self, forKey: .command)
        script = try c.decodeIfPresent(String.self, forKey: .script)
        scriptFile = try c.decodeIfPresent(String.self, forKey: .scriptFile)
        input = try c.decodeIfPresent(Input.self, forKey: .input) ?? .item
        match = try c.decodeIfPresent(String.self, forKey: .match)
        sourceApps = try c.decodeIfPresent([String].self, forKey: .sourceApps)
        shortcut = try c.decodeIfPresent(String.self, forKey: .shortcut)
        globalShortcut = try c.decodeIfPresent(String.self, forKey: .globalShortcut)
        output = try c.decodeIfPresent(Output.self, forKey: .output) ?? .none
        ignore = try c.decodeIfPresent(Bool.self, forKey: .ignore) ?? false
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? 10
        multiple = try c.decodeIfPresent(Multiple.self, forKey: .multiple) ?? .each
        separator = try c.decodeIfPresent(String.self, forKey: .separator)
        saveOutput = try c.decodeIfPresent(Bool.self, forKey: .saveOutput) ?? true
        if let names = try c.decodeIfPresent([String].self, forKey: .types) {
            types = Set(try names.map { name in
                guard let type = SearchQuery.ContentType(rawValue: name.lowercased()) else {
                    throw DecodingError.dataCorruptedError(forKey: .types, in: c, debugDescription:
                        "“\(name)”: unknown type; use text, rich, image, file, link, color or other")
                }
                return type
            })
        } else {
            types = nil
        }
        regex = try match.map { try NSRegularExpression(pattern: $0) }
        sequence = try c.decodeIfPresent(String.self, forKey: .sequence)
        if let sequence {
            do {
                steps = try SequenceStep.parse(sequence)
            } catch {
                throw DecodingError.dataCorruptedError(forKey: .sequence, in: c, debugDescription: "“\(name)”: \(error)")
            }
        } else {
            steps = nil
        }
    }


    var localShortcut: Shortcut? { shortcut.flatMap(Shortcut.init) }

    var keysDisplay: String? {
        let keys = [localShortcut?.display, globalShortcut.flatMap(Shortcut.init).map { L("%@ global", $0.display) }].compactMap { $0 }
        return keys.isEmpty ? nil : keys.joined(separator: " · ")
    }

    var displayName: String { L(name) }

    enum Engine {
        case javaScript(source: String)
        case shell(String)
    }

    func engine() throws -> Engine? {
        if let script { return .javaScript(source: script) }
        if let scriptFile {
            let url = AppPaths.scripts.appendingPathComponent(scriptFile)
            do {
                return .javaScript(source: try String(contentsOf: url, encoding: .utf8))
            } catch {
                throw ScriptError(message: L("Cannot read %@: %@", url.path, error.localizedDescription))
            }
        }
        return command.map { .shell($0) }
    }

    var usesShell: Bool { script == nil && scriptFile == nil && command != nil }

    func accepts(_ subject: CommandSubject) -> Bool {
        !(types ?? [.text, .file]).isDisjoint(with: subject.types)
    }

    func applies(to subject: CommandSubject, sourceApp: String?) -> Bool {
        if input == .none { return true }
        if let apps = sourceApps, !apps.isEmpty {
            guard let sourceApp, apps.contains(sourceApp) else { return false }
        }
        guard accepts(subject) else { return false }
        guard let regex else { return true }
        guard let text = subject.text else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func saveSequence(name: String, steps: String, replacing original: String?) throws {
        _ = try SequenceStep.parse(steps)
        let entry: [String: Any] = ["name": name, "sequence": steps]
        func json(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
                   as: UTF8.self)
        }
        let text = try String(contentsOf: AppPaths.commands, encoding: .utf8)
        let updated: String
        if let original {
            guard let range = sequenceRange(named: original, in: text) else {
                throw ScriptError(message: L("Couldn't find “%@” in commands.json.", original))
            }
            let existing = (try? JSONSerialization.jsonObject(with: Data(text[range].utf8))) as? [String: Any] ?? [:]
            updated = text.replacingCharacters(in: range, with: try json(existing.merging(entry) { $1 }))
        } else {
            let line = try json(entry)
            guard let end = text.lastIndex(of: "]") else { throw ScriptError(message: L("commands.json isn't a JSON list.")) }
            let before = text[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            updated = before + (before.hasSuffix("[") ? "\n  " : ",\n  ") + line + "\n" + text[end...]
        }
        guard (try? JSONSerialization.jsonObject(with: Data(updated.utf8))) is [Any] else {
            throw ScriptError(message: L("commands.json isn't a JSON list."))
        }
        try Data(updated.utf8).write(to: AppPaths.commands, options: .atomic)
    }

    static func deleteSequence(named name: String) throws {
        let text = try String(contentsOf: AppPaths.commands, encoding: .utf8)
        guard let range = sequenceRange(named: name, in: text) else {
            throw ScriptError(message: L("Couldn't find “%@” in commands.json.", name))
        }
        var lower = range.lowerBound
        var upper = range.upperBound
        if let next = text[upper...].firstIndex(where: { !$0.isWhitespace }), text[next] == "," {
            upper = text.index(after: next)
        } else if let previous = text[..<lower].lastIndex(where: { !$0.isWhitespace }), text[previous] == "," {
            lower = previous
        }
        while lower > text.startIndex, " \t".contains(text[text.index(before: lower)]) { lower = text.index(before: lower) }
        while upper < text.endIndex, " \t".contains(text[upper]) { upper = text.index(after: upper) }
        if lower == text.startIndex || text[text.index(before: lower)] == "\n", upper < text.endIndex, text[upper] == "\n" {
            upper = text.index(after: upper)
        }
        let updated = text.replacingCharacters(in: lower..<upper, with: "")
        guard (try? JSONSerialization.jsonObject(with: Data(updated.utf8))) is [Any] else {
            throw ScriptError(message: L("commands.json isn't a JSON list."))
        }
        try Data(updated.utf8).write(to: AppPaths.commands, options: .atomic)
    }

    private static func sequenceRange(named name: String, in text: String) -> Range<String.Index>? {
        var depth = 0
        var inString = false
        var escaped = false
        var start: String.Index?
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"":
                inString = true
            case "{", "[":
                if depth == 1, character == "{" { start = index }
                depth += 1
            case "}", "]":
                depth -= 1
                guard depth == 1, character == "}", let begin = start else { continue }
                start = nil
                let range = begin..<text.index(after: index)
                if let object = try? JSONSerialization.jsonObject(with: Data(text[range].utf8)) as? [String: Any],
                   object["name"] as? String == name, object["sequence"] != nil {
                    return range
                }
            default:
                break
            }
        }
        return nil
    }

    static func load() throws -> (commands: [UserCommand], skipped: [String]) {
        if !FileManager.default.fileExists(atPath: AppPaths.commands.path) {
            try Data(defaultCommandsJSON.utf8).write(to: AppPaths.commands)
        }
        let decoded = try JSONDecoder().decode([UserCommand].self, from: Data(contentsOf: AppPaths.commands))
        let builtIn = try JSONDecoder().decode([UserCommand].self, from: Data(builtInCommandsJSON.utf8))
            .filter { command in !decoded.contains { $0.name == command.name } }
        let all = (decoded + builtIn).filter(\.enabled)
        let unsafe = all.filter { $0.type == .automatic && $0.usesShell }
        return (all.filter { !($0.type == .automatic && $0.usesShell) }, unsafe.map(\.name))
    }

    private static let builtInCommandsJSON = #"""
    [
      {"name": "Resize image to 50%", "types": ["image"], "script": "clip.image.resize(item.image, { scale: 0.5 })", "output": "newItem"},
      {"name": "Resize image to fit 1024 px", "types": ["image"], "script": "clip.image.resize(item.image, { max: 1024 })", "output": "newItem"},
      {"name": "Rotate image right", "types": ["image"], "script": "clip.image.rotate(item.image, 90)", "output": "newItem"},
      {"name": "Rotate image left", "types": ["image"], "script": "clip.image.rotate(item.image, -90)", "output": "newItem"},
      {"name": "Flip image horizontally", "types": ["image"], "script": "clip.image.flip(item.image, 'horizontal')", "output": "newItem"},
      {"name": "Make image grayscale", "types": ["image"], "script": "clip.image.grayscale(item.image)", "output": "newItem"},
      {"name": "Convert image to JPEG", "types": ["image"], "script": "clip.image.convert(item.image, 'jpeg', { quality: 0.85 })", "output": "newItem"},
      {"name": "Convert image to PNG", "types": ["image"], "script": "clip.image.convert(item.image, 'png')", "output": "newItem"},
      {"name": "Copy image as data URL", "types": ["image"], "script": "clip.image.toDataURL(item.image)", "output": "copy"},
      {"name": "Paste as AI context", "script": "let n = 3;\nfor (const run of text.match(/`+/g) || []) if (run.length >= n) n = run.length + 1;\nconst fence = '`'.repeat(n);\nconst app = (item.sourceApp || '').split('.').pop();\nreturn (app ? 'From ' + app + ':\\n' : '') + fence + '\\n' + text.replace(/\\n?$/, '\\n') + fence;", "output": "paste", "separator": "\n\n", "saveOutput": false},
      {"name": "Paste without terminal colours", "match": "\u001b", "script": "text.replace(/\\u001b\\][^\\u0007\\u001b]*(?:\\u0007|\\u001b\\\\)/g, '').replace(/\\u001b\\[[0-?]*[ -\\/]*[@-~]/g, '').replace(/\\u001b[ -\\/]*[0-~]/g, '')", "output": "paste", "saveOutput": false},
      {"name": "Paste with secrets redacted", "script": "const rules = [\n  [/-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, '[PRIVATE KEY]'],\n  [/\\b(?:sk|pk|rk)-(?:proj-|ant-[a-z0-9]+-)?[A-Za-z0-9_-]{20,}/g, '[API KEY]'],\n  [/\\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}/g, '[API KEY]'],\n  [/\\bgh[pousr]_[A-Za-z0-9]{36,}/g, '[GITHUB TOKEN]'],\n  [/\\bgithub_pat_[A-Za-z0-9_]{22,}/g, '[GITHUB TOKEN]'],\n  [/\\bglpat-[A-Za-z0-9_-]{20,}/g, '[GITLAB TOKEN]'],\n  [/\\b(?:AKIA|ASIA)[A-Z0-9]{16}\\b/g, '[AWS KEY]'],\n  [/\\bxox[abposr]-[A-Za-z0-9-]{10,}/g, '[SLACK TOKEN]'],\n  [/\\bAIza[0-9A-Za-z_-]{35}/g, '[GOOGLE KEY]'],\n  [/\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}/g, '[JWT]'],\n  [/\\b(Bearer|Basic|Token)\\s+[A-Za-z0-9._~+\\/=-]{16,}/gi, '$1 [TOKEN]'],\n  [/(\\/\\/[^\\/\\s:@]+):[^@\\s\\/]+@/g, '$1:[PASSWORD]@'],\n  [/((?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret|private[_-]?key)[\"']?\\s*[:=]\\s*[\"']?)[^\\s\"',;]{4,}/gi, '$1[REDACTED]'],\n  [/(\\/Users\\/)(?!Shared\\b)[^\\/\\s\"'<>:]+/g, '$1[user]'],\n  [/(\\/home\\/)[^\\/\\s\"'<>:]+/g, '$1[user]'],\n  [/\\b([A-Za-z]:\\\\Users\\\\)(?:[^\\\\\\n\"'<>:]+(?=\\\\)|[^\\\\\\s\"'<>:]+)/g, '$1[user]'],\n  [/\\b[A-Za-z_][\\w.-]*@[A-Za-z0-9-]+(?:\\.local)?(?=[\\s:~]|$)/gm, '[user]@[host]'],\n  [/\\b[A-Za-z0-9-]+\\.local\\b/g, '[host]'],\n];\nlet out = rules.reduce((t, [re, to]) => t.replace(re, to), text);\nconst escape = (s) => s.replace(/[.*+?^${}()|[\\]\\\\\\/]/g, '\\\\$&');\nfor (const rule of clip.redactions || []) {\n  const literal = /^\\/(.+)\\/([a-z]*)$/s.exec(rule.match);\n  const flags = literal ? (literal[2].includes('g') ? literal[2] : literal[2] + 'g') : 'giu';\n  let re;\n  try {\n    re = new RegExp(literal ? literal[1] : '(^|[^\\\\p{L}\\\\p{N}_])(' + escape(rule.match) + ')(?=[^\\\\p{L}\\\\p{N}_]|$)', flags);\n  } catch (e) {\n    throw new Error('redact in config.json: ' + rule.match + ' is not a valid pattern (' + e.message + ')');\n  }\n  const to = rule.with || '[REDACTED]';\n  out = literal ? out.replace(re, to) : out.replace(re, (m, before) => before + to);\n}\nreturn out;", "output": "paste", "saveOutput": false}
    ]
    """#

    private static let defaultCommandsJSON = #"""
    [
      {"name": "Generate UUID", "input": "none", "script": "clip.uuid()", "output": "paste"},
      {"name": "Generate UUID without dashes", "input": "none", "script": "clip.uuid().replaceAll('-', '')", "output": "paste"},
      {"name": "Generate random SHA-1", "input": "none", "script": "clip.randomHex(20)", "output": "paste"},
      {"name": "Generate password (24 chars)", "input": "none", "script": "clip.randomBase64(18)", "output": "paste"},
      {"name": "Insert ISO timestamp (UTC)", "input": "none", "script": "new Date().toISOString().replace(/\\.\\d{3}Z$/, 'Z')", "output": "paste"},
      {"name": "Insert Unix timestamp", "input": "none", "script": "String(Math.floor(Date.now() / 1000))", "output": "paste"},
      {"name": "SHA-1 of item", "script": "clip.hash('sha1', text)", "output": "paste"},
      {"name": "SHA-256 of item", "script": "clip.hash('sha256', text)", "output": "paste"},
      {"name": "MD5 of item", "script": "clip.hash('md5', text)", "output": "paste"},
      {"name": "Base64 encode", "script": "clip.base64Encode(text)", "output": "paste"},
      {"name": "Base64 decode", "match": "^\\s*[A-Za-z0-9+/=\\s]+$", "script": "clip.base64Decode(text)", "output": "paste"},
      {"name": "Paste trimmed", "type": "menu", "script": "text.trim()", "output": "paste", "shortcut": "cmd+t"},
      {"name": "Paste UPPERCASE", "type": "menu", "script": "text.toUpperCase()", "output": "paste", "shortcut": "cmd+u"},
      {"name": "Paste lowercase", "type": "menu", "script": "text.toLowerCase()", "output": "paste"},
      {"name": "Paste Title Case", "type": "menu", "script": "text.replace(/([\\p{L}\\d])([\\p{L}\\d\\u2019']*)/gu, (m, first, rest) => first.toUpperCase() + rest.toLowerCase())", "output": "paste"},
      {"name": "Paste snake_case", "type": "menu", "script": "text.split('\\n').map(line => line.replace(/[\\u2019']/g, '').replace(/(\\p{Ll}|\\d)(\\p{Lu})/gu, '$1_$2').replace(/(\\p{Lu})(\\p{Lu}\\p{Ll})/gu, '$1_$2').replace(/[^\\p{L}\\d]+/gu, '_').replace(/^_+|_+$/g, '').toLowerCase()).join('\\n')", "output": "paste"},
      {"name": "Paste camelCase", "type": "menu", "script": "text.split('\\n').map(line => { const words = line.replace(/[\\u2019']/g, '').replace(/(\\p{Ll}|\\d)(\\p{Lu})/gu, '$1 $2').replace(/(\\p{Lu})(\\p{Lu}\\p{Ll})/gu, '$1 $2').split(/[^\\p{L}\\d]+/u).filter(w => w); return words.map((w, i) => i === 0 ? w.toLowerCase() : w[0].toUpperCase() + w.slice(1).toLowerCase()).join(''); }).join('\\n')", "output": "paste"},
      {"name": "Paste as ``` code block", "type": "menu", "script": "let n = 3; for (const run of text.match(/`+/g) || []) if (run.length >= n) n = run.length + 1; const fence = '`'.repeat(n); return fence + '\\n' + text.replace(/\\n?$/, '\\n') + fence;", "output": "paste"},
      {"name": "Paste as ~~~ code block", "type": "menu", "script": "let n = 3; for (const run of text.match(/~+/g) || []) if (run.length >= n) n = run.length + 1; const fence = '~'.repeat(n); return fence + '\\n' + text.replace(/\\n?$/, '\\n') + fence;", "output": "paste"},
      {"name": "Pretty-print JSON", "type": "menu", "match": "^\\s*[\\[{]", "script": "JSON.stringify(JSON.parse(text), null, 2)", "output": "replace"},
      {"name": "Open URL in browser", "type": "menu", "match": "^\\s*https?://\\S+\\s*$", "command": "xargs open", "output": "none", "globalShortcut": "ctrl+alt+o"},
      {"name": "Don't save one-time codes", "type": "automatic", "match": "^\\s*\\d{4,8}\\s*$", "ignore": true},
      {"name": "Remove tracking parameters from copied links", "type": "automatic", "enabled": false, "match": "^\\s*https?://\\S+\\s*$", "script": "text.trim().replace(/([?&])(?:utm_[^=&#]*|fbclid|gclid|mc_eid)=[^&#]*/g, '$1').replace(/([?&])&+/g, '$1').replace(/[?&]+(#|$)/, '$1')", "output": "replace"}
    ]
    """#
}

struct CommandResult {
    let status: Int32
    let output: String
    let error: String
    var image: Representation? = nil
}

enum CommandRunner {
    private static let queue = DispatchQueue(label: "clipsie.commands", attributes: .concurrent)

    static func run(_ command: String, input: String, environment: [String: String], timeout: TimeInterval,
                    completion: @escaping (CommandResult) -> Void) {
        queue.async {
            let result = runSync(command, input: input, environment: environment, timeout: timeout)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private final class Buffer {
        var data = Data()
    }

    private static func runSync(_ command: String, input: String, environment: [String: String],
                                timeout: TimeInterval) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = AppPaths.scripts

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [AppPaths.scripts.path, "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]
            .joined(separator: ":")
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        environment.forEach { env[$0.key] = $0.value }
        process.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: "", error: error.localizedDescription)
        }

        let writer = stdin.fileHandleForWriting
        DispatchQueue.global().async {
            try? writer.write(contentsOf: Data(input.utf8))
            try? writer.close()
        }
        let errorBuffer = Buffer()
        let errorDone = DispatchGroup()
        errorDone.enter()
        let errorReader = stderr.fileHandleForReading
        DispatchQueue.global().async {
            errorBuffer.data = (try? errorReader.readToEnd()) ?? Data()
            errorDone.leave()
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        let output = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        killer.cancel()
        errorDone.wait()

        var error = String(decoding: errorBuffer.data, as: UTF8.self)
        if process.terminationReason == .uncaughtSignal {
            error = L("Terminated (timeout after %@ s?)", String(Int(timeout))) + "\n" + error
        }
        return CommandResult(status: process.terminationStatus,
                             output: String(decoding: output, as: UTF8.self),
                             error: error)
    }
}

enum CommandUsage {
    private static let usageKey = "commandUsage"
    private static let lastKey = "lastCommand"

    static var last: String? { UserDefaults.standard.string(forKey: lastKey) }

    static func record(_ name: String) {
        var usage = UserDefaults.standard.dictionary(forKey: usageKey) as? [String: [Double]] ?? [:]
        usage[name] = [(usage[name]?.first ?? 0) + 1, Date().timeIntervalSince1970]
        UserDefaults.standard.set(usage, forKey: usageKey)
        UserDefaults.standard.set(name, forKey: lastKey)
    }

    static func ranked(_ commands: [UserCommand]) -> [UserCommand] {
        let usage = UserDefaults.standard.dictionary(forKey: usageKey) as? [String: [Double]] ?? [:]
        let now = Date().timeIntervalSince1970
        let scores = commands.map { command -> Double in
            guard let entry = usage[command.name], entry.count == 2 else { return 0 }
            return entry[0] * pow(0.5, max(0, now - entry[1]) / (7 * 86_400))
        }
        return commands.indices.sorted { (scores[$0], -$0) > (scores[$1], -$1) }.map { commands[$0] }
    }

    static func pin(_ names: [String], in palette: String) {
        let rest = pinned(palette).filter { !names.contains($0) }
        UserDefaults.standard.set(names + rest, forKey: "commandOrder." + palette)
    }

    static func arranged(_ commands: [UserCommand], in palette: String) -> [UserCommand] {
        var position: [String: Int] = [:]
        for (index, name) in pinned(palette).enumerated() where position[name] == nil { position[name] = index }
        let top = commands.filter { position[$0.name] != nil }.sorted { position[$0.name]! < position[$1.name]! }
        return top + ranked(commands.filter { position[$0.name] == nil })
    }

    private static func pinned(_ palette: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: "commandOrder." + palette) ?? []
    }
}
