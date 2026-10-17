import AppKit
import TextLensKit
import UniformTypeIdentifiers

/// Every capture action, from the menu, a shortcut, or a dropped file.
@MainActor
final class Capture {
    static let shared = Capture()

    /// The area last captured, for "Capture Again".
    private(set) var lastRegion: ScreenRegion? {
        didSet { AppDefaults.store.set(try? JSONEncoder().encode(lastRegion), forKey: "lastRegion") }
    }

    private init() {
        if let data = AppDefaults.store.data(forKey: "lastRegion") {
            lastRegion = try? JSONDecoder().decode(ScreenRegion.self, from: data)
        }
    }

    // MARK: Text

    func captureText() {
        let app = SourceApp.front
        Task {
            guard let selection = await RegionSelector.shared.select(prompt: "Drag over the text to copy") else { return }
            lastRegion = selection.region
            await readText(selection.image, near: selection.globalFrame, app: app)
        }
    }

    /// Reads the same area as last time, straight from the live screen.
    func captureAgain() {
        guard let region = lastRegion, let frame = region.globalFrame else {
            Notice.shared.show(error: "Capture some text first; then this reads the same area again.")
            return
        }
        guard ScreenAccess.granted else { ScreenAccess.explainDenied(); return }
        let app = SourceApp.front
        Task {
            do {
                let image = try await region.camera().capture()
                await readText(image, near: frame, app: app)
            } catch {
                Notice.shared.show(error: "Couldn't capture that area", near: frame)
            }
        }
    }

    private func readText(_ image: CGImage, near frame: CGRect?, app: SourceApp) async {
        Activity.shared.touch()
        let prefs = Preferences.shared
        do {
            let text = try await Recognizer.text(in: image, keepLineBreaks: prefs.keepLineBreaks, options: .current)
            guard !text.isEmpty else {
                Sounds.failure()
                Notice.shared.show(error: "No text found", near: frame)
                return
            }
            deliver(text, image: image, near: frame, app: app)
        } catch {
            Sounds.failure()
            Notice.shared.show(error: "Text recognition failed", near: frame)
            NSLog("TextLens: recognition failed: \(error.localizedDescription)")
        }
    }

    /// Copies recognized text and does whatever else Settings asks for.
    private func deliver(_ text: String, image: CGImage?, near frame: CGRect?, app: SourceApp) {
        let prefs = Preferences.shared
        Clipboard.copy(text)
        Sounds.success()
        let count = text.count
        let what = prefs.additiveClipboard ? "Added \(count) characters to the clipboard" : "Copied \(count) character\(count == 1 ? "" : "s")"
        Notice.shared.show(what, symbol: "text.viewfinder", near: frame)
        HistoryStore.shared.add(kind: .text, text: text, app: app, image: image)
        ActivityStore.shared.record(.text)
        if prefs.speakAfterCapture { Speech.shared.speak(text) }
        if prefs.openLinks, let url = Self.firstLink(in: text) { NSWorkspace.shared.open(url) }
    }

    static func firstLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
    }

    // MARK: Codes

    func captureCode() {
        let app = SourceApp.front
        Task {
            guard let selection = await RegionSelector.shared.select(prompt: "Drag over a QR or bar code",
                                                                     tint: .systemPurple) else { return }
            await readCodes(selection.image, near: selection.globalFrame, app: app)
        }
    }

    private func readCodes(_ image: CGImage, near frame: CGRect?, app: SourceApp) async {
        Activity.shared.touch()
        do {
            let payloads = try await Recognizer.codes(in: image)
            guard !payloads.isEmpty else {
                Sounds.failure()
                Notice.shared.show(error: "No QR or bar code found", near: frame)
                return
            }
            let joined = payloads.joined(separator: "\n")
            Clipboard.copy(joined)
            Sounds.success()
            for payload in payloads { HistoryStore.shared.add(kind: .code, text: payload, app: app, image: image) }
            ActivityStore.shared.record(.code)
            if Preferences.shared.openLinks, payloads.count == 1, case .url(let url) = CodePayload.parse(payloads[0]) {
                NSWorkspace.shared.open(url)
                Notice.shared.show("Opened \(url.host ?? "link")", symbol: "qrcode", near: frame)
            } else {
                CodeResultPanel.shared.show(payloads, near: frame)
            }
        } catch {
            Sounds.failure()
            Notice.shared.show(error: "Couldn't read codes", near: frame)
        }
    }

    // MARK: Translation

    func captureAndTranslate() {
        let app = SourceApp.front
        Task {
            guard let selection = await RegionSelector.shared.select(prompt: "Drag over the text to translate",
                                                                     tint: .systemIndigo) else { return }
            lastRegion = selection.region
            Activity.shared.touch()
            let panel = TranslationPanelController.shared
            _ = panel.showReading(near: selection.globalFrame)
            do {
                let text = try await Recognizer.text(in: selection.image, keepLineBreaks: Preferences.shared.keepLineBreaks,
                                                     options: .current)
                guard !text.isEmpty else { panel.fail("No text found in that area."); return }
                panel.translate(text: text, near: selection.globalFrame, image: selection.image, app: app)
            } catch {
                panel.fail("Text recognition failed.")
            }
        }
    }

    func toggleLiveTranslation() {
        if LiveTranslator.shared.isRunning { LiveTranslator.shared.stop(); return }
        Task {
            guard let selection = await RegionSelector.shared.select(prompt: "Drag over the area to translate live",
                                                                     tint: .systemBlue) else { return }
            LiveTranslator.shared.start(selection)
        }
    }

    // MARK: Watch

    func watchRegion() {
        let app = SourceApp.front
        Task {
            guard let selection = await RegionSelector.shared.select(prompt: "Drag over the area to watch",
                                                                     tint: .systemGreen) else { return }
            WatchManager.shared.setUp(selection, app: app)
        }
    }

    // MARK: Files and the clipboard

    func recognizeFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose pictures or PDFs to read text from"
        guard panel.runModal() == .OK else { return }
        recognize(files: panel.urls)
    }

    /// Reads text from image and PDF files, one result per file, all copied together.
    func recognize(files: [URL]) {
        let app = SourceApp(name: nil, bundleID: nil)
        Task {
            var texts: [String] = []
            var firstImage: CGImage?
            for url in files {
                let images: [CGImage]
                if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
                    images = Recognizer.pageImages(ofPDF: url)
                } else if let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    images = [image]
                } else {
                    images = []
                }
                firstImage = firstImage ?? images.first
                var pages: [String] = []
                for image in images {
                    if let text = try? await Recognizer.text(in: image, keepLineBreaks: Preferences.shared.keepLineBreaks,
                                                             options: .current), !text.isEmpty {
                        pages.append(text)
                    }
                }
                if !pages.isEmpty { texts.append(pages.joined(separator: "\n\n")) }
            }
            guard !texts.isEmpty else {
                Sounds.failure()
                Notice.shared.show(error: files.count == 1 ? "No text found in that file" : "No text found in those files")
                return
            }
            deliver(texts.joined(separator: "\n\n"), image: firstImage, near: nil, app: app)
        }
    }

    func recognizeClipboardImage() {
        guard let image = Clipboard.image else {
            Notice.shared.show(error: "There's no picture on the clipboard")
            return
        }
        Task {
            // Copied pictures often hold codes too: read both and report what was there.
            if let codes = try? await Recognizer.codes(in: image), !codes.isEmpty,
               (try? await Recognizer.text(in: image, keepLineBreaks: true, options: .current))?.count ?? 0 < 4 {
                await readCodes(image, near: nil, app: SourceApp(name: nil, bundleID: nil))
            } else {
                await readText(image, near: nil, app: SourceApp(name: nil, bundleID: nil))
            }
        }
    }
}
