import AppKit
import SwiftUI
import Translation

struct TranslationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// On-device translation through Apple's Translation framework. Nothing leaves the Mac;
/// a language pair that isn't downloaded yet is fetched once, after macOS asks.
@Observable
@MainActor
final class Translator {
    static let shared = Translator()

    struct Result {
        var text: String
        var source: Locale.Language
        var target: Locale.Language
        /// The text was already in the target language, so it came back unchanged.
        var sameLanguage: Bool
    }

    /// Languages the framework can translate between, sorted by name.
    private(set) var languages: [Locale.Language] = []
    @ObservationIgnored private var sessions: [String: TranslationSession] = [:]

    func loadLanguages() async {
        guard languages.isEmpty else { return }
        let all = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        languages = all.filter { seen.insert($0.minimalIdentifier).inserted }
            .sorted { Self.name($0).localizedCaseInsensitiveCompare(Self.name($1)) == .orderedAscending }
    }

    /// The language translations go into: the one chosen in Settings, or the Mac's own.
    var defaultTarget: Locale.Language {
        let stored = Preferences.shared.targetLanguage
        return stored.isEmpty ? Locale.current.language : Locale.Language(identifier: stored)
    }

    static func name(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    /// Translates line by line, so lists, tables and paragraph breaks keep their shape.
    func translate(_ text: String, to target: Locale.Language, from knownSource: Locale.Language? = nil,
                   allowDownload: Bool = true) async throws -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationFailure(message: "There's no text to translate.") }
        guard let source = knownSource ?? Recognizer.language(of: trimmed) else {
            throw TranslationFailure(message: "TextLens couldn't tell what language this is.")
        }
        if source.languageCode == target.languageCode && source.script == target.script {
            return Result(text: text, source: source, target: target, sameLanguage: true)
        }

        let session = try await session(from: source, to: target, allowDownload: allowDownload)
        let lines = text.components(separatedBy: "\n")
        let requests = lines.enumerated().compactMap { index, line -> TranslationSession.Request? in
            line.trimmingCharacters(in: .whitespaces).isEmpty ? nil
                : TranslationSession.Request(sourceText: line, clientIdentifier: String(index))
        }
        let responses = try await session.translations(from: requests)
        var output = lines
        for response in responses {
            if let id = response.clientIdentifier, let index = Int(id), output.indices.contains(index) {
                output[index] = response.targetText
            }
        }
        return Result(text: output.joined(separator: "\n"), source: source, target: target, sameLanguage: false)
    }

    private func session(from source: Locale.Language, to target: Locale.Language,
                         allowDownload: Bool) async throws -> TranslationSession {
        let key = "\(source.minimalIdentifier)>\(target.minimalIdentifier)"
        if let session = sessions[key] { return session }
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            break
        case .supported:
            guard allowDownload else {
                throw TranslationFailure(message: "\(Self.name(source)) to \(Self.name(target)) needs a one-time download first.")
            }
            // The download sheet can be dismissed without downloading; check it really happened.
            guard await TranslationDownloader.prepare(source: source, target: target),
                  await LanguageAvailability().status(from: source, to: target) == .installed else {
                throw TranslationFailure(message: "Translating \(Self.name(source)) to \(Self.name(target)) needs those languages downloaded. Try again and choose Download.")
            }
        case .unsupported:
            throw TranslationFailure(message: "macOS can't translate \(Self.name(source)) to \(Self.name(target)).")
        @unknown default:
            break
        }
        let session = TranslationSession(installedSource: source, target: target)
        sessions[key] = session
        return session
    }
}

/// Downloading a language pair needs SwiftUI's `translationTask`, which shows the system's
/// download prompt. This puts up a small window to host it.
@MainActor
enum TranslationDownloader {
    private static var window: NSWindow?

    static func prepare(source: Locale.Language, target: Locale.Language) async -> Bool {
        await withCheckedContinuation { continuation in
            var finished = false
            @MainActor func finish(_ ok: Bool) {
                guard !finished else { return }
                finished = true
                Self.window?.orderOut(nil)
                Self.window = nil
                continuation.resume(returning: ok)
            }
            let view = DownloadView(configuration: .init(source: source, target: target),
                                    title: "\(Translator.name(source)) → \(Translator.name(target))") { ok in finish(ok) }
            let host = NSWindow(contentViewController: NSHostingController(rootView: view))
            host.title = "Translation Languages"
            host.styleMask = [.titled, .closable]
            host.isReleasedWhenClosed = false
            host.center()
            let closer = WindowCloseObserver { finish(false) }
            host.delegate = closer
            objc_setAssociatedObject(host, "closer", closer, .OBJC_ASSOCIATION_RETAIN)
            Self.window = host
            NSApp.activate(ignoringOtherApps: true)
            host.makeKeyAndOrderFront(nil)
        }
    }

    private struct DownloadView: View {
        let configuration: TranslationSession.Configuration
        let title: String
        let done: (Bool) -> Void

        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle").font(.system(size: 34)).foregroundStyle(.tint)
                Text("Getting \(title) ready").font(.headline)
                Text("macOS downloads these languages once, then translates on this Mac without the internet.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                ProgressView().controlSize(.small)
            }
            .padding(24)
            .frame(width: 340)
            .translationTask(configuration) { session in
                do {
                    try await session.prepareTranslation()
                    done(true)
                } catch {
                    NSLog("TextLens: translation download failed: \(error.localizedDescription)")
                    done(false)
                }
            }
        }
    }
}

final class WindowCloseObserver: NSObject, NSWindowDelegate {
    let onClose: @MainActor () -> Void
    init(onClose: @escaping @MainActor () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { onClose() }
    }
}
