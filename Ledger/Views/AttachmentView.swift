import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import LedgerKit

// Receipts and other files attached to a transaction: the file goes to documents/ in the
// ledger, and a `document` directive linked with the transaction's ^link points at it.

/// repository path of a document directive's file (relative to the file the directive is in)
func documentRepoPath(_ e: Entry) -> String? {
    guard let path = e.path else { return nil }
    return documentPath(path, from: e.file)
}

func relativePath(_ target: String, from file: String) -> String {
    relativeDocumentPath(target, from: file)
}

extension Store {
    /// documents linked to a transaction. Links that tie a whole group together (a reimbursement, petty cash,
    /// a refund, a subscription, a month's salary) don't make a document this transaction's own.
    func documents(for t: Entry) -> [Entry] {
        guard let L = L else { return [] }
        let links = Set(t.links.filter { LinkRole.of($0) == .other && !isSalaryLink($0) })
        if links.isEmpty { return [] }
        return L.entries.filter { $0.type == .document && !links.isDisjoint(with: $0.links) }
    }

    /// upload a file and link it to the transaction
    func attach(_ data: Data, ext: String, to t: Entry) async {
        guard let L = L else { return }
        let safe = (t.payee.isEmpty ? t.narration : t.payee).unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0.value > 0x2E80 ? String($0) : "-" }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let rnd = String(UUID().uuidString.prefix(4)).lowercased()
        let repoPath = "documents/\(t.date.prefix(4))/\(t.date)-\(safe.isEmpty ? "receipt" : String(safe.prefix(24)))-\(rnd).\(ext)"
        // the transaction's own doc- link: a shared one (^float-…, ^reimburse-…) would attach the file to the whole group
        let link = t.links.first(where: { $0.hasPrefix("doc-") }) ?? "doc-\(t.date.replacingOccurrences(of: "-", with: ""))-\(rnd)"
        let account = t.postings.first { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") }?.account ?? t.postings.first?.account ?? ""
        show(LS("正在上传附件…"))
        do {
            try await backend.writeData(repoPath, data: data, message: LS("附件：%@", repoPath))
        } catch {
            show(LS("上传失败：%@", error.localizedDescription))
            return
        }
        let line = "\(t.date) document \(account) \"\(repoPath)\" ^\(link)"
        guard var ops = makeOps(line, extra: OpExtra(label: LS("附件：%@ %@", t.date, t.payee)), single: false) else { return }
        // the path in the directive is relative to the file it is written to
        for i in ops.indices where ops[i].kind == .insert {
            ops[i].text = ops[i].text?.replacingOccurrences(of: "\"\(repoPath)\"", with: "\"\(relativePath(repoPath, from: ops[i].path))\"")
        }
        if !t.links.contains(link), let file = try? await fileText(t.file) {
            let lines = file.components(separatedBy: "\n")
            if t.startLine < lines.count {
                var op = Op(kind: .link, path: t.file)
                op.headerLine = t.startLine + 1
                op.header = lines[t.startLine]
                op.add = " ^" + link
                op.link = link
                op.silent = true
                ops.append(op)
            }
        }
        _ = L
        await commit(ops, word: LS("已添加附件"))
    }
}

/// shrink a photo for the ledger repository
func jpegForUpload(_ image: UIImage) -> Data? {
    let maxSide: CGFloat = 2000
    let s = image.size
    let scale = min(1, maxSide / max(s.width, s.height))
    let size = CGSize(width: s.width * scale, height: s.height * scale)
    let r = UIGraphicsImageRenderer(size: size)
    let img = r.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    return img.jpegData(compressionQuality: 0.72)
}

struct AttachmentsSection: View {
    @EnvironmentObject var store: Store
    let t: Entry
    @State private var choosing = false
    @State private var photo: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var viewing: DocItem?

    var body: some View {
        let docs = store.documents(for: t)
        Section {
            ForEach(Array(docs.enumerated()), id: \.offset) { _, d in
                Button {
                    if let p = documentRepoPath(d) { viewing = DocItem(path: p) }
                } label: {
                    HStack {
                        Image(systemName: icon(d.path ?? "")).foregroundStyle(Color.jade)
                        Text(((d.path ?? "") as NSString).lastPathComponent).lineLimit(1)
                        Spacer()
                        Text(d.date).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
            Button { choosing = true } label: { Label(LS("添加附件"), systemImage: "paperclip") }
            // presentations hang off this one row: on the Section they would be copied onto every row
            .confirmationDialog(LS("添加附件"), isPresented: $choosing) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) { Button(LS("拍照")) { showCamera = true } }
                Button(LS("从照片选择")) { showPhotos = true }
                Button(LS("从文件选择")) { showFiles = true }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
            .onChange(of: photo) { _, item in
                guard let item = item else { return }
                Task {
                    if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d), let jpg = jpegForUpload(img) {
                        await store.attach(jpg, ext: "jpg", to: t)
                    }
                    photo = nil
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .image, .data]) { result in
                guard case .success(let url) = result else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                guard let d = try? Data(contentsOf: url) else { return }
                let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension.lowercased()
                Task { await store.attach(d, ext: ext, to: t) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { img in
                    showCamera = false
                    if let img = img, let jpg = jpegForUpload(img) { Task { await store.attach(jpg, ext: "jpg", to: t) } }
                }
                .ignoresSafeArea()
            }
            .sheet(item: $viewing) { DocumentViewer(path: $0.path) }
        } header: {
            Text(LS("附件"))
        }
    }

    private func icon(_ p: String) -> String {
        let e = (p as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(e) ? "photo" : e == "pdf" ? "doc.richtext" : "doc"
    }
}

struct DocItem: Identifiable { let path: String; var id: String { path } }

/// downloads a file from the ledger storage and shows it with Quick Look
struct DocumentViewer: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let path: String
    @State private var url: URL?
    @State private var error: String?
    @State private var retry = 0
    @State private var temporaryFolder: URL?

    var body: some View {
        NavigationStack {
            Group {
                if let u = url { QuickLookView(url: u) }
                else if let e = error {
                    VStack(spacing: 16) {
                        Text(e).foregroundStyle(.secondary)
                        Button(LS("重试")) { retry += 1 }
                    }.padding()
                }
                else { ProgressView() }
            }
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(LS("完成")) { dismiss() } }
                if let u = url { ToolbarItem(placement: .topBarLeading) { ShareLink(item: u) } }
            }
        }
        .task(id: retry) {
            error = nil
            do {
                let d = try await store.backend.readData(path)
                try Task.checkCancellation()
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-document-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                temporaryFolder = dir
                let f = dir.appendingPathComponent((path as NSString).lastPathComponent)
                try d.write(to: f, options: .atomic)
                url = f
            } catch is CancellationError {
                return
            } catch {
                self.error = LS("无法下载：%@", error.localizedDescription)
            }
        }
        .onChange(of: store.cfg.id) { _, _ in dismiss() }
        .onDisappear {
            if let dir = temporaryFolder { try? FileManager.default.removeItem(at: dir) }
        }
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }
    func updateUIViewController(_ c: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }
    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}
