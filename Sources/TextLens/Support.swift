import AppKit
import AVFoundation
import Observation
import SwiftUI

/// What TextLens is doing right now, so an automatic update waits for a quiet moment.
@Observable
@MainActor
final class Activity {
    static let shared = Activity()
    private(set) var lastActive = Date.distantPast

    func touch() { lastActive = Date() }

    var busyReason: String? {
        if RegionSelector.shared.isSelecting { return "a region is being selected" }
        if !WatchManager.shared.watches.isEmpty { return "a region is being watched" }
        if LiveTranslator.shared.isRunning { return "live translation is on" }
        if Speech.shared.isSpeaking { return "text is being read aloud" }
        return nil
    }
}

/// Copying results, with TextLens's "additive" mode that appends to what is
/// already on the clipboard.
@MainActor
enum Clipboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        var value = text
        if Preferences.shared.additiveClipboard, let existing = pasteboard.string(forType: .string), !existing.isEmpty {
            value = existing + "\n" + text
        }
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    static func copyImage(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    /// The image on the clipboard, if there is one (a copied picture or an image file).
    static var image: CGImage? {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, let image = NSImage(contentsOf: url) {
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let image = NSImage(pasteboard: pasteboard) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// Reading text aloud.
@Observable
@MainActor
final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speech()
    private(set) var isSpeaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        let rate = Float(Preferences.shared.speechRate)
        utterance.rate = AVSpeechUtteranceMinimumSpeechRate + (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * rate
        if let language = Recognizer.language(of: text) {
            utterance.voice = AVSpeechSynthesisVoice(language: language.maximalIdentifier)
                ?? AVSpeechSynthesisVoice(language: language.languageCode?.identifier ?? "")
        }
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if !self.synthesizer.isSpeaking { self.isSpeaking = false } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in if !self.synthesizer.isSpeaking { self.isSpeaking = false } }
    }
}

/// The app that was in front when a capture started, for the history.
struct SourceApp {
    let name: String?
    let bundleID: String?

    @MainActor static var front: SourceApp {
        let app = NSWorkspace.shared.frontmostApplication
        guard app?.processIdentifier != getpid() else { return SourceApp(name: nil, bundleID: nil) }
        return SourceApp(name: app?.localizedName, bundleID: app?.bundleIdentifier)
    }
}

/// A floating panel that hosts SwiftUI and doesn't steal focus until clicked.
@MainActor
class FloatingPanel: NSPanel {
    init(title: String, size: CGSize, resizable: Bool = true) {
        var style: NSWindow.StyleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        self.title = title
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }

    /// Shows SwiftUI content, sized to fit it, so placement works with the real size.
    func host<V: View>(_ view: V) {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        contentViewController = hosting
        let fitting = hosting.view.fittingSize
        if fitting.width > 10 && fitting.height > 10 { setContentSize(fitting) }
    }

    /// Puts the panel beside `anchor` (a global rect) without covering it: below if there
    /// is room, else above, else to the right or left.
    func place(near anchor: CGRect?) {
        let size = frame.size
        let point = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var origin: CGPoint
        if let anchor {
            let gap: CGFloat = 12
            if anchor.minY - gap - size.height >= visible.minY {
                origin = CGPoint(x: anchor.minX, y: anchor.minY - gap - size.height)
            } else if anchor.maxY + gap + size.height <= visible.maxY {
                origin = CGPoint(x: anchor.minX, y: anchor.maxY + gap)
            } else if anchor.maxX + gap + size.width <= visible.maxX {
                origin = CGPoint(x: anchor.maxX + gap, y: anchor.maxY - size.height)
            } else {
                origin = CGPoint(x: anchor.minX - gap - size.width, y: anchor.maxY - size.height)
            }
        } else {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrameOrigin(origin)
    }
}
