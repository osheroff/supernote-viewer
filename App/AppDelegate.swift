import AppKit
import SwiftUI

/// Opening a .note or .mark file renders it to a PDF and hands it to Preview, then quits.
/// Launched on its own, the app shows a short info window instead.
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var receivedFiles = false
    private var pendingJobs = 0
    private var infoWindow: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PreviewHandoff.cleanCache()
        // Files arrive via application(_:open:) right after launch; without any, show the info window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if !receivedFiles { showInfoWindow() }
        }
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        receivedFiles = true
        pendingJobs += 1
        Task { @MainActor in
            await PreviewHandoff.open(urls)
            pendingJobs -= 1
            if pendingJobs == 0 && infoWindow == nil {
                NSApp.terminate(nil)
            }
        }
    }

    private func showInfoWindow() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: InfoView()))
        window.title = "Supernote Viewer"
        window.styleMask = [.titled, .closable]
        window.delegate = self
        window.center()
        infoWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        infoWindow = nil
        if pendingJobs == 0 { NSApp.terminate(nil) }
    }
}

struct InfoView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Supernote Viewer").font(.title2.bold())
            Text("Double-click a .note or .pdf.mark file to open it in Preview, with sharp handwriting you can search, select and highlight. Press Space in Finder for a quick look.")
            Text("For .mark files, keep the original PDF next to it (X.pdf.mark → X.pdf).")
                .foregroundStyle(.secondary)
            Text("Preview opens a generated copy. To keep your Preview annotations, use File → Export or Duplicate. If the notebook changes, the copy is regenerated, but a copy you saved changes to is never overwritten.")
                .foregroundStyle(.secondary)
            Text("If Quick Look previews don't appear, enable \"Supernote Quick Look\" in System Settings → General → Login Items & Extensions → Quick Look.")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 480)
        .fixedSize()
    }
}
