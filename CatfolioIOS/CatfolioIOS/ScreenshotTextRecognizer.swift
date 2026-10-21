import Foundation
import Vision
import ImageIO

enum ScreenshotTextRecognizer {
    static func recognize(_ data: Data) async throws -> [ScreenshotTextBox] {
        let work = Task.detached(priority: .userInitiated) {
            guard data.count <= 30 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096
                  ] as CFDictionary) else {
                throw ScreenshotImportError(message: L10n.text("无法读取图片，请选择小于 30 MB 的清晰持仓截图。"))
            }
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            try Task.checkCancellation()
            return (request.results ?? []).flatMap { observation -> [ScreenshotTextBox] in
                guard let candidate = observation.topCandidates(1).first else { return [] }
                // Keep actual word geometry; proportional string slicing would
                // move narrow digits into the wrong financial column.
                let regex = try! NSRegularExpression(pattern: #"\S+"#)
                let text = candidate.string
                return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                    guard let range = Range(match.range, in: text),
                          let rectangle = try? candidate.boundingBox(for: range)?.boundingBox else { return nil }
                    return ScreenshotTextBox(text: String(text[range]), x: rectangle.minX,
                        y: 1 - rectangle.maxY, width: rectangle.width, height: rectangle.height)
                }
            }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
