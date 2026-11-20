import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import JavaScriptCore
import Security
import UniformTypeIdentifiers

struct ScriptInput {
    let text: String
    let itemID: Int64?
    let sourceApp: String?
    let types: [String]
    var image: Data? = nil
}

final class ScriptEngine {
    static let commands = ScriptEngine(label: "commands")
    static let plugins = ScriptEngine(label: "plugins")

    static var historyProvider: ((Int) -> [String])?
    static var redactions: [[String: String]] = []

    private let queue: DispatchQueue
    private let machine: JSVirtualMachine
    private var compiled: [String: (context: JSContext, function: JSValue)] = [:]
    private var images: [Int: ScriptImage] = [:]
    private var nextImageID = 1

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
        images.removeAll()
        defer { images.removeAll() }
        let item = JSValue(newObjectIn: context)!
        if let data = input.image, let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            item.setObject(handle(ScriptImage(image: image), in: context), forKeyedSubscript: "image" as NSString)
        } else {
            item.setObject(NSNull(), forKeyedSubscript: "image" as NSString)
        }
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
        if let image = scriptImage(value) {
            guard let encoded = image.encoded() else { return .failure(ScriptError(message: L("Could not encode the image."))) }
            return .success(.image(encoded))
        }
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
        clip.setObject(imageAPI(in: context), forKeyedSubscript: "image" as NSString)
        clip.setObject(Self.redactions, forKeyedSubscript: "redactions" as NSString)
        context.setObject(clip, forKeyedSubscript: "clip" as NSString)
        let console = JSValue(newObjectIn: context)!
        console.setObject(object(log), forKeyedSubscript: "log" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    private func handle(_ image: ScriptImage, in context: JSContext) -> JSValue {
        let id = nextImageID
        nextImageID += 1
        images[id] = image
        let object = JSValue(newObjectIn: context)!
        object.setObject(image.image.width, forKeyedSubscript: "width" as NSString)
        object.setObject(image.image.height, forKeyedSubscript: "height" as NSString)
        object.setObject(image.format, forKeyedSubscript: "format" as NSString)
        object.setObject(id, forKeyedSubscript: "__clipsieImage" as NSString)
        return object
    }

    private func scriptImage(_ value: JSValue) -> ScriptImage? {
        guard value.isObject, let id = value.objectForKeyedSubscript("__clipsieImage"), id.isNumber else { return nil }
        return images[Int(id.toInt32())]
    }

    private func imageAPI(in context: JSContext) -> JSValue {
        let api = JSValue(newObjectIn: context)!
        func define<T>(_ name: String, _ block: T) {
            api.setObject(unsafeBitCast(block, to: AnyObject.self), forKeyedSubscript: name as NSString)
        }
        func number(_ options: JSValue, _ key: String) -> Double? {
            guard options.isObject, let value = options.objectForKeyedSubscript(key), value.isNumber else { return nil }
            return value.toDouble()
        }
        let transform: (JSValue, (ScriptImage) throws -> ScriptImage) -> JSValue = { [weak self] value, change in
            let context = JSContext.current()!
            guard let self, let image = self.scriptImage(value) else {
                context.exception = JSValue(newErrorFromMessage: L("Not an image; use item.image."), in: context)
                return JSValue(undefinedIn: context)
            }
            do {
                return self.handle(try change(image), in: context)
            } catch {
                context.exception = JSValue(newErrorFromMessage: "\(error)", in: context)
                return JSValue(undefinedIn: context)
            }
        }
        let resize: @convention(block) (JSValue, JSValue) -> JSValue = { value, options in
            transform(value) { image in
                let width = Double(image.image.width), height = Double(image.image.height)
                let size: (Double, Double)
                if let scale = number(options, "scale") {
                    size = (width * scale, height * scale)
                } else {
                    let targetWidth = number(options, "width"), targetHeight = number(options, "height")
                    let maxSide = number(options, "max")
                    switch (targetWidth, targetHeight, maxSide) {
                    case let (w?, h?, _): size = (w, h)
                    case let (w?, nil, _): size = (w, height * w / width)
                    case let (nil, h?, _): size = (width * h / height, h)
                    case let (nil, nil, m?): size = width >= height ? (min(m, width), height * min(m, width) / width)
                                                                    : (width * min(m, height) / height, min(m, height))
                    default: throw ScriptError(message: L("resize needs width, height, max or scale."))
                    }
                }
                return try image.resized(width: size.0, height: size.1)
            }
        }
        define("resize", resize)
        let crop: @convention(block) (JSValue, JSValue) -> JSValue = { value, options in
            transform(value) { image in
                guard let width = number(options, "width"), let height = number(options, "height") else {
                    throw ScriptError(message: L("crop needs x, y, width and height."))
                }
                return try image.cropped(x: number(options, "x") ?? 0, y: number(options, "y") ?? 0, width: width, height: height)
            }
        }
        define("crop", crop)
        let rotate: @convention(block) (JSValue, Double) -> JSValue = { value, degrees in
            transform(value) { try $0.rotated(degrees: degrees) }
        }
        define("rotate", rotate)
        let flip: @convention(block) (JSValue, String) -> JSValue = { value, direction in
            transform(value) { try $0.flipped(vertically: direction.lowercased().hasPrefix("v")) }
        }
        define("flip", flip)
        let grayscale: @convention(block) (JSValue) -> JSValue = { value in
            transform(value) { try $0.grayscale() }
        }
        define("grayscale", grayscale)
        let convert: @convention(block) (JSValue, String, JSValue) -> JSValue = { value, format, options in
            transform(value) { image in
                guard ScriptImage.formats[format.lowercased()] != nil else {
                    throw ScriptError(message: L("Unknown image format “%@”; use png, jpeg, heic or tiff.", format))
                }
                var converted = image
                converted.format = format.lowercased()
                converted.quality = min(1, max(0, number(options, "quality") ?? 0.85))
                return converted
            }
        }
        define("convert", convert)
        let dataURL: @convention(block) (JSValue) -> JSValue = { [weak self] value in
            let context = JSContext.current()!
            guard let image = self?.scriptImage(value), let encoded = image.encoded() else {
                context.exception = JSValue(newErrorFromMessage: L("Not an image; use item.image."), in: context)
                return JSValue(undefinedIn: context)
            }
            let mime = ScriptImage.formats[image.format]?.mime ?? "image/png"
            return JSValue(object: "data:\(mime);base64," + encoded.data.base64EncodedString(), in: context)
        }
        define("toDataURL", dataURL)
        return api
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
    case image(Representation)
}

struct ScriptImage {
    static let formats: [String: (type: UTType, pasteboard: String, mime: String)] = [
        "png": (.png, "public.png", "image/png"),
        "jpeg": (.jpeg, "public.jpeg", "image/jpeg"),
        "jpg": (.jpeg, "public.jpeg", "image/jpeg"),
        "heic": (.heic, "public.heic", "image/heic"),
        "tiff": (.tiff, "public.tiff", "image/tiff"),
    ]
    private static let maxSide = 16_384

    let image: CGImage
    var format = "png"
    var quality = 0.85

    private func drawn(width: Int, height: Int, gray: Bool = false, background: CGColor? = nil,
                       _ body: (CGContext) -> Void) throws -> ScriptImage {
        guard width > 0, height > 0, width <= Self.maxSide, height <= Self.maxSide else {
            throw ScriptError(message: L("Image size %@×%@ is out of range.", String(width), String(height)))
        }
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let alpha = gray ? CGImageAlphaInfo.none : CGImageAlphaInfo.premultipliedLast
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: alpha.rawValue) else {
            throw ScriptError(message: L("Could not create the image."))
        }
        context.interpolationQuality = .high
        if let background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        body(context)
        guard let result = context.makeImage() else { throw ScriptError(message: L("Could not create the image.")) }
        return ScriptImage(image: result, format: format, quality: quality)
    }

    func resized(width: Double, height: Double) throws -> ScriptImage {
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= Double(Self.maxSide), height <= Double(Self.maxSide) else {
            throw ScriptError(message: L("Image size %@×%@ is out of range.", String(width), String(height)))
        }
        let pixelsWide = Int(width.rounded()), pixelsHigh = Int(height.rounded())
        return try drawn(width: pixelsWide, height: pixelsHigh) {
            $0.draw(image, in: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        }
    }

    func cropped(x: Double, y: Double, width: Double, height: Double) throws -> ScriptImage {
        guard [x, y, width, height].allSatisfy(\.isFinite) else { throw ScriptError(message: L("The crop area is outside the image.")) }
        let rect = CGRect(x: x, y: y, width: width, height: height).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isNull, !rect.isEmpty, let result = image.cropping(to: rect) else {
            throw ScriptError(message: L("The crop area is outside the image."))
        }
        return ScriptImage(image: result, format: format, quality: quality)
    }

    func rotated(degrees: Double) throws -> ScriptImage {
        guard degrees.isFinite, abs(degrees) < 1_000_000 else {
            throw ScriptError(message: L("rotate only turns by multiples of 90 degrees."))
        }
        let turns = ((Int((degrees / 90).rounded()) % 4) + 4) % 4
        guard Double(turns * 90) == (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) else {
            throw ScriptError(message: L("rotate only turns by multiples of 90 degrees."))
        }
        let width = turns % 2 == 0 ? image.width : image.height
        let height = turns % 2 == 0 ? image.height : image.width
        return try drawn(width: width, height: height) { context in
            context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            context.rotate(by: -CGFloat(turns) * .pi / 2)
            context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                           width: CGFloat(image.width), height: CGFloat(image.height)))
        }
    }

    func flipped(vertically: Bool) throws -> ScriptImage {
        try drawn(width: image.width, height: image.height) { context in
            if vertically {
                context.translateBy(x: 0, y: CGFloat(image.height))
                context.scaleBy(x: 1, y: -1)
            } else {
                context.translateBy(x: CGFloat(image.width), y: 0)
                context.scaleBy(x: -1, y: 1)
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    func grayscale() throws -> ScriptImage {
        try drawn(width: image.width, height: image.height, gray: true, background: CGColor(gray: 1, alpha: 1)) {
            $0.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    func encoded() -> Representation? {
        guard let target = Self.formats[format] else { return nil }
        var source = image
        if target.type == .jpeg, let flattened = try? drawn(width: image.width, height: image.height,
                                                             background: CGColor(red: 1, green: 1, blue: 1, alpha: 1), {
            $0.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }) {
            source = flattened.image
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, target.type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, source, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Representation(itemIndex: 0, type: target.pasteboard, data: data as Data)
    }
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
