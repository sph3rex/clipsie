import CryptoKit
import Foundation
import JavaScriptCore
import Security

struct ScriptInput {
    let text: String
    let itemID: Int64?
    let sourceApp: String?
    let types: [String]
}

final class ScriptEngine {
    static let commands = ScriptEngine(label: "commands")
    static let plugins = ScriptEngine(label: "plugins")

    static var historyProvider: ((Int) -> [String])?

    private let queue: DispatchQueue
    private let machine: JSVirtualMachine
    private var compiled: [String: (context: JSContext, function: JSValue)] = [:]

    private init(label: String) {
        queue = DispatchQueue(label: "clipsie.js.\(label)")
        machine = queue.sync { JSVirtualMachine() }
    }

    func run(_ source: String, name: String, input: ScriptInput, timeout: TimeInterval,
             completion: @escaping (Result<ScriptValue, ScriptError>) -> Void) {
        queue.async {
            let result = self.runSync(source, name: name, input: input, timeout: timeout)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func reset() {
        queue.async { self.compiled.removeAll() }
    }

    private func runSync(_ source: String, name: String, input: ScriptInput,
                         timeout: TimeInterval) -> Result<ScriptValue, ScriptError> {
        let entry: (context: JSContext, function: JSValue)
        if let cached = compiled[source] {
            entry = cached
        } else {
            switch compile(source, name: name) {
            case .success(let new):
                entry = new
                compiled[source] = new
            case .failure(let error):
                return .failure(error)
            }
        }
        let context = entry.context
        context.exception = nil
        let item = JSValue(newObjectIn: context)!
        item.setObject(input.text, forKeyedSubscript: "text" as NSString)
        item.setObject(input.itemID.map { NSNumber(value: $0) } ?? NSNull(), forKeyedSubscript: "id" as NSString)
        item.setObject(input.sourceApp ?? NSNull(), forKeyedSubscript: "sourceApp" as NSString)
        item.setObject(input.types, forKeyedSubscript: "types" as NSString)

        ExecutionLimit.set(timeout, for: context)
        let started = Date()
        let value = entry.function.call(withArguments: [input.text, item])
        ExecutionLimit.set(nil, for: context)

        if let exception = context.exception {
            context.exception = nil
            if Date().timeIntervalSince(started) >= timeout * 0.9 {
                compiled[source] = nil
                return .failure(ScriptError(message: L("Stopped after %@ s (timeout)", String(Int(timeout)))))
            }
            return .failure(ScriptError(message: Self.describe(exception)))
        }
        guard let value, !value.isUndefined, !value.isNull else { return .success(.nothing) }
        if value.isBoolean { return .success(value.toBool() ? .nothing : .ignore) }
        if value.isObject, !value.isArray, let object = value.toDictionary() as? [String: Any] {
            if let result = object["value"] {
                return .success(.text("\(result)", title: object["title"].map { "\($0)" }))
            }
        }
        return .success(.text(value.toString() ?? "", title: nil))
    }

    private func compile(_ source: String, name: String) -> Result<(context: JSContext, function: JSValue), ScriptError> {
        guard let context = JSContext(virtualMachine: machine) else {
            return .failure(ScriptError(message: L("Cannot create a JavaScript context")))
        }
        context.name = name
        installAPI(in: context)
        for wrapped in [
            "(function (text, item) { \"use strict\";\nreturn (\n\(source)\n);\n})",
            "(function (text, item) { \"use strict\";\n\(source)\n})",
        ] {
            context.exception = nil
            if let function = context.evaluateScript(wrapped), context.exception == nil, function.isObject {
                return .success((context, function))
            }
        }
        let message = context.exception.map(Self.describe) ?? L("invalid script")
        return .failure(ScriptError(message: message))
    }

    private static func describe(_ exception: JSValue) -> String {
        let message = exception.toString() ?? "error"
        guard let line = exception.objectForKeyedSubscript("line"), line.isNumber else { return message }
        return L("%@ (line %@)", message, String(max(1, line.toInt32() - 2)))
    }

    private func installAPI(in context: JSContext) {
        let clip = JSValue(newObjectIn: context)!
        func object<T>(_ block: T) -> AnyObject { unsafeBitCast(block, to: AnyObject.self) }
        func define<T>(_ name: String, _ block: T) {
            clip.setObject(object(block), forKeyedSubscript: name as NSString)
        }
        let history: @convention(block) (JSValue) -> [String] = { count in
            let n = count.isNumber ? max(0, min(100, Int(count.toInt32()))) : 10
            return n == 0 ? [] : ScriptEngine.historyProvider?(n) ?? []
        }
        define("history", history)
        let hash: @convention(block) (String, String) -> Any = { algorithm, text in
            Self.hash(algorithm.lowercased(), Data(text.utf8)) ?? NSNull()
        }
        define("hash", hash)
        let encode: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        define("base64Encode", encode)
        let decode: @convention(block) (String) -> Any = { text in
            Data(base64Encoded: text, options: .ignoreUnknownCharacters).flatMap { String(data: $0, encoding: .utf8) }
                ?? NSNull()
        }
        define("base64Decode", decode)
        let uuid: @convention(block) () -> String = { UUID().uuidString.lowercased() }
        define("uuid", uuid)
        let randomHex: @convention(block) (Double) -> String = { count in
            Self.randomBytes(count).map { String(format: "%02x", $0) }.joined()
        }
        define("randomHex", randomHex)
        let randomBase64: @convention(block) (Double) -> String = { Self.randomBytes($0).base64EncodedString() }
        define("randomBase64", randomBase64)
        let log: @convention(block) () -> Void = {
            let parts = (JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }
            NSLog("Clipsie script “\(JSContext.current()?.name ?? "")”: \(parts.joined(separator: " "))")
        }
        define("log", log)
        context.setObject(clip, forKeyedSubscript: "clip" as NSString)
        let console = JSValue(newObjectIn: context)!
        console.setObject(object(log), forKeyedSubscript: "log" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    private static func hash(_ algorithm: String, _ data: Data) -> String? {
        let digest: [UInt8]
        switch algorithm {
        case "md5": digest = Array(Insecure.MD5.hash(data: data))
        case "sha1", "sha-1": digest = Array(Insecure.SHA1.hash(data: data))
        case "sha256", "sha-256": digest = Array(SHA256.hash(data: data))
        case "sha384", "sha-384": digest = Array(SHA384.hash(data: data))
        case "sha512", "sha-512": digest = Array(SHA512.hash(data: data))
        default: return nil
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomBytes(_ count: Double) -> Data {
        let n = count.isFinite ? Int(max(0, min(count, 1024))) : 0
        var data = Data(count: n)
        guard n > 0 else { return data }
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return data
    }
}

enum ScriptValue {
    case nothing
    case ignore
    case text(String, title: String?)
}

struct ScriptError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private enum ExecutionLimit {
    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void
    private typealias ClearLimit = @convention(c) (JSContextGroupRef?) -> Void

    private static let handle = UnsafeMutableRawPointer(bitPattern: -2)
    private static let setLimit = dlsym(handle, "JSContextGroupSetExecutionTimeLimit").map {
        unsafeBitCast($0, to: SetLimit.self)
    }
    private static let clearLimit = dlsym(handle, "JSContextGroupClearExecutionTimeLimit").map {
        unsafeBitCast($0, to: ClearLimit.self)
    }
    private static let terminate: ShouldTerminate = { _, _ in true }

    static func set(_ seconds: TimeInterval?, for context: JSContext) {
        let group = JSContextGetGroup(context.jsGlobalContextRef)
        if let seconds {
            setLimit?(group, seconds, terminate, nil)
        } else {
            clearLimit?(group)
        }
    }
}
