import AppIntents
import UniformTypeIdentifiers
import Vision
import LedgerKit

// 截图记账 (first part): a Shortcuts action takes a screenshot, the phone's own text recognition reads it, and
// the app shows what was read. The image is only held in memory while it is read and is then dropped: it is
// never written to disk, attached, or uploaded.

/// what was read off one screenshot
struct ScanResult: Identifiable, Equatable {
    let id = UUID()
    var boxes: [OCRBox]
    var text: String { ocrText(boxes) }
}

enum ScanError: LocalizedError {
    case unreadable
    var errorDescription: String? { LS("无法读取这张图片") }
}

/// the text in an image, read on this phone (Chinese and English); the image data is not kept
func recognizeText(_ data: Data) async throws -> [OCRBox] {
    try await Task.detached(priority: .userInitiated) {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        req.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(data: data, options: [:])
        do { try handler.perform([req]) } catch { throw ScanError.unreadable }
        return (req.results ?? []).compactMap { o -> OCRBox? in
            guard let t = o.topCandidates(1).first?.string else { return nil }
            // Vision's box has its origin at the bottom left
            let b = o.boundingBox
            return OCRBox(text: t, x: b.minX, y: 1 - b.maxY, w: b.width, h: b.height)
        }
    }.value
}

@MainActor
extension Store {
    /// read a screenshot and show what was read
    func scan(_ data: Data) async {
        do {
            let boxes = try await recognizeText(data)
            if boxes.isEmpty { show(LS("截图里没有识别出文字")); return }
            adding = false
            scanResult = ScanResult(boxes: boxes)
        } catch {
            show(error.localizedDescription)
        }
    }
}

struct ScanRecordIntent: AppIntent {
    static var title: LocalizedStringResource = "截图记账"
    static var description = IntentDescription("识别付款截图里的文字（在本机识别，截图不保存、不上传），在 App 中显示识别结果。可加到分享菜单，或配合「截屏」动作用轻点背面触发。")
    static var openAppWhenRun = true

    @Parameter(title: "截图", supportedContentTypes: [.image]) var image: IntentFile

    static var parameterSummary: some ParameterSummary { Summary("识别 \(\.$image) 并记账") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let data = image.data
        await Store.shared.scan(data)
        return .result()
    }
}
