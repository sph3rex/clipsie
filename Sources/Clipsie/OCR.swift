import Foundation
import ImageIO
import Vision

final class OCR {
    var isEnabled = true
    var languages: [String] = []
    var onRecognized: ((Int64) -> Void)?

    private let store: Store
    private var backfillStarted = false
    private let queue = DispatchQueue(label: "clipsie.ocr", qos: .utility)
    private static let maxPixelSize = 4096

    init(store: Store) {
        self.store = store
    }

    func recognize(_ id: Int64) {
        guard isEnabled else { return }
        queue.async { self.process(id, notify: true) }
    }

    func backfill(again: Bool = false) {
        guard isEnabled, again || !backfillStarted else { return }
        backfillStarted = true
        queue.async {
            for id in self.store.idsNeedingOCR() {
                self.queue.async { self.process(id, notify: false) }
            }
        }
    }

    private func process(_ id: Int64, notify: Bool) {
        guard isEnabled, store.needsOCR(id) else { return }
        let text = Content.imageData(store.representations(for: id)).flatMap(recognizeText) ?? ""
        store.setOCRText(id, text)
        if notify && !text.isEmpty {
            DispatchQueue.main.async { self.onRecognized?(id) }
        }
    }

    private func recognizeText(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty { request.recognitionLanguages = languages }
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            NSLog("Clipsie: text recognition failed: \(error)")
            return nil
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
