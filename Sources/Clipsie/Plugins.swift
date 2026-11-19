import AppKit
import CryptoKit

struct PluginResult {
    let plugin: String
    let value: String
    let title: String
    var command: UserCommand? = nil
}

enum Plugins {
    static let timeout: TimeInterval = 2
    private static var sources: [URL: String] = [:]
    private static let perlCalculatorHash = "ed3776aca72caa2ee24f972838d8b13809304c7b96365f1c99cee49cb5d321d7"

    private static var bundledCalculator: URL? {
        Bundle.main.url(forResource: "calc", withExtension: "js", subdirectory: "plugins")
    }

    static func installDefaults() {
        let fm = FileManager.default
        let calc = AppPaths.plugins.appendingPathComponent("calc.js")
        do {
            guard fm.fileExists(atPath: AppPaths.plugins.path) else {
                try fm.createDirectory(at: AppPaths.plugins, withIntermediateDirectories: true)
                try installCalculator(at: calc)
                return
            }
            let perl = AppPaths.plugins.appendingPathComponent("calc")
            if let data = fm.contents(atPath: perl.path), !fm.fileExists(atPath: calc.path),
               SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == perlCalculatorHash {
                try installCalculator(at: calc)
                try fm.removeItem(at: perl)
            }
        } catch {
            NSLog("Clipsie: cannot install default plugins: \(error)")
        }
    }

    private static func installCalculator(at url: URL) throws {
        guard let source = bundledCalculator else {
            throw StoreError(description: "calc.js isn't in the app bundle (Contents/Resources/plugins)")
        }
        try FileManager.default.copyItem(at: source, to: url)
    }

    static func load(active: [String]) -> [URL] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: AppPaths.plugins, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles])) ?? [])
            .filter { active.contains($0.lastPathComponent) }
        sources = [:]
        for file in files where file.pathExtension == "js" {
            do {
                sources[file] = try String(contentsOf: file, encoding: .utf8)
            } catch {
                NSLog("Clipsie: cannot read plugin \(file.lastPathComponent): \(error)")
            }
        }
        return files.filter { sources[$0] != nil || fm.isExecutableFile(atPath: $0.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func run(_ plugins: [URL], query: String, completion: @escaping ([PluginResult]) -> Void) {
        var results: [Int: PluginResult] = [:]
        let group = DispatchGroup()
        for (index, plugin) in plugins.enumerated() {
            group.enter()
            let name = plugin.lastPathComponent
            if let source = sources[plugin] {
                let input = ScriptInput(text: query, itemID: nil, sourceApp: nil, types: [])
                ScriptEngine.plugins.run(source, name: name, input: input, timeout: timeout) { result in
                    switch result {
                    case .success(.text(let value, let title)) where !value.isEmpty:
                        results[index] = PluginResult(plugin: name, value: value, title: title ?? value)
                    case .failure(let error):
                        NSLog("Clipsie: plugin \(name) failed: \(error)")
                    default:
                        break
                    }
                    group.leave()
                }
                continue
            }
            let command = "exec '" + plugin.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            CommandRunner.run(command, input: query, environment: ["CLIP_QUERY": query], timeout: timeout) { result in
                let lines = result.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                if result.status == 0, let value = lines.first, !value.isEmpty {
                    let title = lines.count > 1 && !lines[1].isEmpty ? lines[1] : value
                    results[index] = PluginResult(plugin: name, value: value, title: title)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(results.keys.sorted().compactMap { results[$0] })
        }
    }
}
