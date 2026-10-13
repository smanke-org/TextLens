import AppKit
import SwiftUI
import TextLensKit

/// What a translation panel shows.
@Observable
@MainActor
final class TranslationModel {
    enum Status: Equatable {
        case reading, translating, done, failed(String)
    }

    var original = ""
    var translated = ""
    var source: Locale.Language?
    var target: Locale.Language
    var status = Status.reading
    var sameLanguage = false
    var showOriginal = false
    var isLive = false
    var lastUpdate: Date?

    @ObservationIgnored var onTargetChange: ((Locale.Language) -> Void)?
    @ObservationIgnored var onStop: (() -> Void)?

    init(target: Locale.Language) { self.target = target }
}

struct TranslationView: View {
    @Bindable var model: TranslationModel
    @State private var translator = Translator.shared
    @State private var speech = Speech.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch model.status {
                    case .reading:
                        placeholder(model.isLive ? "Watching for text…" : "Reading text…")
                    case .translating where model.translated.isEmpty:
                        placeholder("Translating…")
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    default:
                        if model.sameLanguage {
                            Text("Already in \(Translator.name(model.target)).").font(.callout).foregroundStyle(.secondary)
                        }
                        Text(model.translated)
                            .font(.system(size: 15))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if model.showOriginal && !model.original.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Original").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(model.original)
                                .font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 60)
            footer
        }
        .padding(14)
        .padding(.top, 14)
        .frame(minWidth: 320, minHeight: 160)
        .task { await translator.loadLanguages() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if model.isLive {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.red)
                    .symbolEffect(.pulse, isActive: model.status != .reading)
            }
            Text(model.source.map(Translator.name) ?? "Detecting…")
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            Picker("To", selection: Binding(get: { model.target.minimalIdentifier },
                                            set: { id in
                                                let language = Locale.Language(identifier: id)
                                                model.target = language
                                                model.onTargetChange?(language)
                                            })) {
                if !translator.languages.contains(where: { $0.minimalIdentifier == model.target.minimalIdentifier }) {
                    Text(Translator.name(model.target)).tag(model.target.minimalIdentifier)
                }
                ForEach(translator.languages, id: \.minimalIdentifier) { language in
                    Text(Translator.name(language)).tag(language.minimalIdentifier)
                }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            if model.status == .translating || model.status == .reading { ProgressView().controlSize(.small) }
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            Toggle("Original", isOn: $model.showOriginal).toggleStyle(.checkbox).controlSize(.small)
            Spacer()
            if model.isLive, let date = model.lastUpdate {
                Text(date, format: .dateTime.hour().minute().second()).font(.caption).foregroundStyle(.tertiary)
            }
            Button {
                speech.isSpeaking ? speech.stop() : speech.speak(model.translated)
            } label: { Image(systemName: speech.isSpeaking ? "stop.fill" : "speaker.wave.2") }
                .help("Read the translation aloud")
                .disabled(model.translated.isEmpty)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.translated, forType: .string)
                Notice.shared.show("Translation copied")
            }
            .disabled(model.translated.isEmpty)
            if model.isLive {
                Button("Stop") { model.onStop?() }.keyboardShortcut(.cancelAction)
            }
        }
        .controlSize(.small)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One-shot translations of a capture: a floating panel next to what was selected.
@MainActor
final class TranslationPanelController {
    static let shared = TranslationPanelController()
    private var panel: FloatingPanel?
    private var model: TranslationModel?
    private var task: Task<Void, Never>?

    /// Shows the panel and fills it in once `text` is translated.
    func translate(text: String, near anchor: CGRect?, image: CGImage?, app: SourceApp, saveToHistory: Bool = true) {
        let model = TranslationModel(target: Translator.shared.defaultTarget)
        model.original = text
        model.status = .translating
        show(model, near: anchor)
        model.onTargetChange = { [weak self] language in
            self?.run(model, to: language, image: image, app: app, saveToHistory: saveToHistory, copy: false)
        }
        run(model, to: model.target, image: image, app: app, saveToHistory: saveToHistory, copy: true)
    }

    /// Shows the panel in its "reading" state while the capture is read.
    func showReading(near anchor: CGRect?) -> TranslationModel {
        let model = TranslationModel(target: Translator.shared.defaultTarget)
        show(model, near: anchor)
        return model
    }

    func fail(_ message: String) {
        model?.status = .failed(message)
    }

    private func show(_ model: TranslationModel, near anchor: CGRect?) {
        task?.cancel()
        self.model = model
        let panel = self.panel ?? FloatingPanel(title: "Translation", size: CGSize(width: 440, height: 260))
        panel.contentViewController = NSHostingController(rootView: TranslationView(model: model))
        panel.setContentSize(CGSize(width: max(440, min(640, (anchor?.width ?? 440))), height: 260))
        panel.place(near: anchor)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func run(_ model: TranslationModel, to target: Locale.Language, image: CGImage?, app: SourceApp,
                     saveToHistory: Bool, copy: Bool) {
        task?.cancel()
        model.status = .translating
        if model.source == nil { model.source = Recognizer.language(of: model.original) }
        task = Task {
            do {
                let result = try await Translator.shared.translate(model.original, to: target)
                guard !Task.isCancelled else { return }
                model.source = result.source
                model.translated = result.text
                model.sameLanguage = result.sameLanguage
                model.status = .done
                if copy { copyResult(model) }
                if saveToHistory {
                    HistoryStore.shared.add(kind: .translation, text: model.original, translation: result.text,
                                            sourceLanguage: result.source.minimalIdentifier,
                                            targetLanguage: result.target.minimalIdentifier, app: app, image: image)
                }
            } catch {
                guard !Task.isCancelled else { return }
                model.status = .failed(error.localizedDescription)
            }
        }
    }

    private func copyResult(_ model: TranslationModel) {
        switch Preferences.shared.translationCopy {
        case .translation: Clipboard.copy(model.translated)
        case .original: Clipboard.copy(model.original)
        case .both: Clipboard.copy(model.original + "\n\n" + model.translated)
        case .nothing: return
        }
        Sounds.success()
    }
}

/// Live translation of a region: reads it every second or so and re-translates whenever
/// the text changes, for subtitles, chats, games and slides in another language.
@Observable
@MainActor
final class LiveTranslator {
    static let shared = LiveTranslator()
    private(set) var isRunning = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private var cover: CoverWindow?
    @ObservationIgnored private var outline: OutlineWindow?
    @ObservationIgnored private var model: TranslationModel?

    func start(_ selection: RegionSelector.Selection) {
        stop()
        isRunning = true
        Activity.shared.touch()
        let model = TranslationModel(target: Translator.shared.defaultTarget)
        model.isLive = true
        model.onStop = { [weak self] in self?.stop() }
        self.model = model

        let frame = selection.globalFrame
        if Preferences.shared.liveCoversOriginal {
            let cover = CoverWindow(frame: frame, model: model)
            cover.orderFrontRegardless()
            self.cover = cover
            Notice.shared.show("Live translation on. \(Preferences.shared.liveTranslateHotKey?.display ?? "The menu") stops it.",
                               symbol: "translate", tint: .systemBlue, near: frame, duration: 2.5)
        } else {
            let panel = FloatingPanel(title: "Live Translation", size: CGSize(width: max(380, min(frame.width, 700)), height: 260))
            panel.contentViewController = NSHostingController(rootView: TranslationView(model: model))
            panel.setContentSize(CGSize(width: max(380, min(frame.width, 700)), height: 260))
            panel.place(near: frame)
            panel.delegate = closer
            panel.orderFrontRegardless()
            self.panel = panel
            let outline = OutlineWindow(frame: frame, color: .systemBlue, label: "Live Translation")
            outline.orderFrontRegardless()
            self.outline = outline
        }
        model.onTargetChange = { _ in model.translated = ""; self.forceRefresh = true }
        loop(camera: selection.region.camera(), model: model)
    }

    @ObservationIgnored private var forceRefresh = false
    @ObservationIgnored private lazy var closer = WindowCloseObserver { [weak self] in self?.stop() }

    func stop() {
        task?.cancel()
        task = nil
        if let panel { panel.delegate = nil; panel.close() }
        panel = nil
        cover?.orderOut(nil)
        cover = nil
        outline?.orderOut(nil)
        outline = nil
        model = nil
        if isRunning { isRunning = false; Activity.shared.touch() }
    }

    private func loop(camera: ScreenGrabber.RegionCamera, model: TranslationModel) {
        task = Task { [weak self] in
            var lastRead = ""
            // Offer a language download once; asking again every second would be maddening.
            var downloadOffered = false
            while !Task.isCancelled {
                let started = Date()
                do {
                    let image = try await camera.capture()
                    let text = try await Recognizer.text(in: image, keepLineBreaks: Preferences.shared.keepLineBreaks,
                                                         options: .current)
                    let force = self?.forceRefresh ?? false
                    self?.forceRefresh = false
                    if force { downloadOffered = false }
                    if text.isEmpty {
                        if model.translated.isEmpty { model.status = .reading }
                    } else if force || ChangeDetector.similarity(text, lastRead) < 0.97 {
                        lastRead = text
                        model.original = text
                        model.source = Recognizer.language(of: text) ?? model.source
                        model.status = .translating
                        let result = try await Translator.shared.translate(text, to: model.target, allowDownload: !downloadOffered)
                        guard !Task.isCancelled else { return }
                        model.source = result.source
                        model.translated = result.text
                        model.sameLanguage = result.sameLanguage
                        model.status = .done
                        model.lastUpdate = Date()
                        Activity.shared.touch()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    downloadOffered = true
                    lastRead = ""
                    model.status = .failed(error.localizedDescription)
                    // A missing language pair won't fix itself; wait longer before retrying.
                    try? await Task.sleep(for: .seconds(4))
                }
                let interval = Preferences.shared.liveInterval
                let elapsed = Date().timeIntervalSince(started)
                try? await Task.sleep(for: .seconds(max(0.2, interval - elapsed)))
            }
        }
    }
}

/// A thin colored frame around a region being watched or translated, which clicks pass
/// through. Screen captures leave it out, so it never shows up in what's read.
final class OutlineWindow: NSWindow {
    init(frame: CGRect, color: NSColor, label: String) {
        let inset: CGFloat = 4
        super.init(contentRect: frame.insetBy(dx: -inset, dy: -inset), styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = OutlineView(color: color, label: label)
        view.frame = CGRect(origin: .zero, size: self.frame.size)
        contentView = view
    }

    func flash() {
        guard let layer = contentView?.layer else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.15
        pulse.duration = 0.18
        pulse.autoreverses = true
        pulse.repeatCount = 3
        layer.add(pulse, forKey: "flash")
    }

    private final class OutlineView: NSView {
        let color: NSColor
        let label: String
        init(color: NSColor, label: String) {
            self.color = color
            self.label = label
            super.init(frame: .zero)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            color.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 5, yRadius: 5)
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.stroke()
        }
    }
}

/// Live translation drawn straight over the original text.
private final class CoverWindow: NSWindow {
    init(frame: CGRect, model: TranslationModel) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentViewController = NSHostingController(rootView: CoverView(model: model))
        setFrame(frame, display: false)
    }

    private struct CoverView: View {
        var model: TranslationModel
        var body: some View {
            Text(model.translated.isEmpty ? (model.status == .reading ? "…" : model.original) : model.translated)
                .font(.system(size: 28, weight: .medium))
                .minimumScaleFactor(0.2)
                .foregroundStyle(.primary)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
