import Quartz
import SupernoteKit
import UniformTypeIdentifiers

/// Data-based Quick Look preview: renders the Supernote file to a multi-page PDF.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let pdf = try PDFRenderer.render(contentsOf: request.fileURL)

        var size = CGSize(width: 800, height: 1066)
        if let provider = CGDataProvider(data: pdf as CFData),
           let page = CGPDFDocument(provider)?.page(at: 1) {
            size = page.getBoxRect(.mediaBox).size
        }
        return QLPreviewReply(dataOfContentType: .pdf, contentSize: size) { _ in pdf }
    }
}
