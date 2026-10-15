import AppIntents
import UniformTypeIdentifiers
import Vision
import LedgerKit

// 截图记账 (first part): a Shortcuts action takes a screenshot, the phone's own text recognition reads it, and
// the app shows what was read. The image is only held in memory while it is read and is then dropped: it is
// never written to disk, attached, or uploaded.

/// what was read off one screenshot (and, when it couldn't be filled in, why)
struct ScanResult: Identifiable, Equatable {
    let id = UUID()
    var boxes: [OCRBox]
    var problem: String? = nil
    var text: String { ocrText(boxes) }
}

/// a card filled in from a screenshot: what to check before saving
struct ScanInfo {
    var boxes: [OCRBox]
    var checks: [ScanCheck]
    var duplicate: Entry?
    var refundOf: [Entry]
    /// the card as remembered ("4321"), and the account it was taken to be
    var cardKey: String?
    var funding: String
    /// what was read: its currency details are applied again when the paying account changes
    var fields: ScanFields
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
    /// read a screenshot and open the 记一笔 card filled in from it; what was read is shown instead when it
    /// isn't one payment (or no amount was found)
    func scan(_ data: Data) async {
        let boxes: [OCRBox]
        do { boxes = try await recognizeText(data) } catch { show(error.localizedDescription); return }
        if boxes.isEmpty { show(LS("截图里没有识别出文字")); return }
        await ensureLoaded()
        guard let L = L, let D = D else { scanResult = ScanResult(boxes: boxes, problem: LS("账本尚未加载")); return }
        let plan = scanPlan(parseScan(ocrText(boxes)), L, D, cards: repoConfig?.scanCards ?? [:], defaultFunding: defaultFunding)
        guard var d = plan.draft else {
            adding = false
            scanResult = ScanResult(boxes: boxes, problem: plan.problem)
            return
        }
        if d.kind != .transfer && d.events.isEmpty && !d.eventsTouched { d.events = autoEvents(on: d.date) }
        if d.flag.isEmpty { d.flag = "*" }
        scanResult = nil
        adding = false
        draft = d
        scanInfo = ScanInfo(boxes: boxes, checks: plan.checks, duplicate: plan.duplicate, refundOf: plan.refundOf,
                            cardKey: plan.cardKey, funding: d.funding, fields: plan.fields)
        openAdd(full: needsFullForm(d))
    }

    /// the paying account changed on a card filled in from a screenshot: the rate / amount charged / discount
    /// put on for that account, and the 金额已核对 check kept in step
    func scanFundingChanged() {
        guard var info = scanInfo, let L = L, let D = D, draft.replacing == nil else { return }
        var d = draft
        let check = applyScanCurrency(&d, info.fields, L, D)
        info.checks.removeAll { $0 == .charged }
        if check { info.checks.append(.charged) }
        scanInfo = info
        if d != draft { draft = d }
    }

    /// a refund screenshot's purchase picked by hand: the refund drawn up against it, keeping what was read
    func scanRefund(of t: Entry) {
        guard let L = L, let D = D else { return }
        let was = draft
        var d = refundDraft(t, L, D, defaultFunding: defaultFunding)
        d.date = was.date
        d.amount = was.amount
        if !was.funding.isEmpty { d.funding = was.funding }
        draft = d
    }

    /// save a card filled in from a screenshot; the paying account it was saved with is remembered for that card
    /// (in ledger-x.json, all devices) when it isn't already
    func saveScanned() async -> Bool {
        let info = scanInfo
        let funding = draft.funding
        // off before saving: the card then starts a new entry, which is not the screenshot's
        scanInfo = nil
        guard await saveForm() else { scanInfo = info; return false }
        // found by its digits and kept: nothing to remember
        let found = info.map { !$0.checks.contains(.funding) && $0.funding == funding } ?? true
        if !found, let k = info?.cardKey, !funding.isEmpty, repoConfig?.scanCards?[k] != funding,
           funding.hasPrefix("Assets:") || funding.hasPrefix("Liabilities:") {
            await updateConfig(LS("截图记账：%@ 记为 %@", k, acctLabel(funding)), word: LS("已记住付款方式")) {
                var m = $0.scanCards ?? [:]
                m[k] = funding
                $0.scanCards = m
            }
        }
        return true
    }
}

struct ScanRecordIntent: AppIntent {
    static var title: LocalizedStringResource = "截图记账"
    static var description = IntentDescription("识别付款截图里的文字（在本机识别，截图不保存、不上传），在 App 中显示识别结果。可加到分享菜单，或配合「截屏」动作用轻点背面触发。")
    static var openAppWhenRun = true

    @Parameter(title: "截图") var image: IntentFile

    static var parameterSummary: some ParameterSummary { Summary("识别 \(\.$image) 并记账") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let data = image.data
        await Store.shared.scan(data)
        return .result()
    }
}
