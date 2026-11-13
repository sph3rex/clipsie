import Foundation

struct UserCommand: Decodable {
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
    private let regex: NSRegularExpression?

    private enum CodingKeys: String, CodingKey {
        case name, type, enabled, command, script, scriptFile, input, match, sourceApps, shortcut, globalShortcut, output
        case ignore, timeout
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
        regex = try match.map { try NSRegularExpression(pattern: $0) }
    }

    var localShortcut: Shortcut? { shortcut.flatMap(Shortcut.init) }

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
                throw ScriptError(message: "Cannot read \(url.path): \(error.localizedDescription)")
            }
        }
        return command.map { .shell($0) }
    }

    var usesShell: Bool { script == nil && scriptFile == nil && command != nil }

    func applies(to text: String?, sourceApp: String?) -> Bool {
        if input == .none { return true }
        if let apps = sourceApps, !apps.isEmpty {
            guard let sourceApp, apps.contains(sourceApp) else { return false }
        }
        guard let regex else { return true }
        guard let text else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func load() throws -> (commands: [UserCommand], skipped: [String]) {
        if !FileManager.default.fileExists(atPath: AppPaths.commands.path) {
            try Data(defaultCommandsJSON.utf8).write(to: AppPaths.commands)
        }
        let all = try JSONDecoder().decode([UserCommand].self, from: Data(contentsOf: AppPaths.commands))
            .filter(\.enabled)
        let unsafe = all.filter { $0.type == .automatic && $0.usesShell }
        return (all.filter { !($0.type == .automatic && $0.usesShell) }, unsafe.map(\.name))
    }

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
            error = "Terminated (timeout after \(Int(timeout))s?)\n" + error
        }
        return CommandResult(status: process.terminationStatus,
                             output: String(decoding: output, as: UTF8.self),
                             error: error)
    }
}
