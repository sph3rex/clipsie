import AppKit

enum Favicons {
    private static var memory: [String: NSImage] = [:]
    private static var loading: Set<String> = []

    static func image(for url: URL, onLoad: @escaping () -> Void) -> NSImage? {
        let key = url.absoluteString
        if let image = memory[key] { return image }
        let file = AppPaths.favicons.appendingPathComponent(cacheName(url))
        if let image = NSImage(contentsOf: file), image.isValid {
            memory[key] = image
            return image
        }
        guard !loading.contains(key) else { return nil }
        loading.insert(key)
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            DispatchQueue.main.async {
                guard ok, let data, let image = NSImage(data: data), image.isValid else { return }
                try? data.write(to: file)
                memory[key] = image
                onLoad()
            }
        }.resume()
        return nil
    }

    private static func cacheName(_ url: URL) -> String {
        url.absoluteString.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "_" }.reduce(into: "") { $0.append($1) }
    }
}
