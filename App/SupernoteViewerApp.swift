import SwiftUI

@main
struct SupernoteViewerApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("Supernote Viewer").font(.title2.bold())
                Text("The Quick Look extension is installed with this app. Select a .note or .pdf.mark file in Finder and press Space to preview it.")
                Text("For .mark files, keep the original PDF next to it (X.pdf.mark → X.pdf).")
                    .foregroundStyle(.secondary)
                Text("If previews don't appear, enable \"Supernote Quick Look\" in System Settings → General → Login Items & Extensions → Quick Look.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 460)
            .fixedSize()
        }
        .windowResizability(.contentSize)
    }
}
