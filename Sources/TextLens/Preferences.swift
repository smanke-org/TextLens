import AppKit
import Observation
import SwiftUI
import TextLensKit

/// What the Translate panel copies to the clipboard.
enum TranslationCopy: String, CaseIterable {
    case translation, original, both, nothing

    var title: String {
        switch self {
        case .translation: "The translation"
        case .original: "The original text"
        case .both: "Both"
        case .nothing: "Nothing"
        }
    }
}

/// Every setting, persisted to UserDefaults as it changes.
@Observable
@MainActor
final class Preferences {
    static let shared = Preferences()

    // MARK: Capture
    var keepLineBreaks = true { didSet { save(keepLineBreaks, "keepLineBreaks") } }
    /// Vision's accurate recognizer; the fast one is quicker but misses more.
    var accurateRecognition = true { didSet { save(accurateRecognition, "accurateRecognition") } }
    var languageCorrection = true { didSet { save(languageCorrection, "languageCorrection") } }
    var autoDetectLanguage = true { didSet { save(autoDetectLanguage, "autoDetectLanguage") } }
    /// A BCP-47 code such as "en-US", or empty for the system's languages.
    var recognitionLanguage = "" { didSet { save(recognitionLanguage, "recognitionLanguage") } }
    /// Comma-separated words Vision should prefer, for jargon and names.
    var customWords = "" { didSet { save(customWords, "customWords") } }
    var openLinks = false { didSet { save(openLinks, "openLinks") } }
    var playSound = true { didSet { save(playSound, "playSound") } }
    var showNotice = true { didSet { save(showNotice, "showNotice") } }
    /// Each capture is added to what is already on the clipboard instead of replacing it.
    var additiveClipboard = false { didSet { save(additiveClipboard, "additiveClipboard") } }
    var speakAfterCapture = false { didSet { save(speakAfterCapture, "speakAfterCapture") } }
    var speechRate = Defaults.speechRate { didSet { save(speechRate, "speechRate") } }

    // MARK: Translation
    /// A language code such as "fr", or empty for the Mac's own language.
    var targetLanguage = "" { didSet { save(targetLanguage, "targetLanguage") } }
    var translationCopy = TranslationCopy.translation { didSet { save(translationCopy.rawValue, "translationCopy") } }
    var liveInterval = Defaults.liveInterval { didSet { save(liveInterval, "liveInterval") } }
    /// Live translation is drawn over the original text instead of in a panel below it.
    var liveCoversOriginal = false { didSet { save(liveCoversOriginal, "liveCoversOriginal") } }

    // MARK: Watch
    var watchInterval = Defaults.watchInterval { didSet { save(watchInterval, "watchInterval") } }
    var watchTrigger = WatchTrigger.anyChange { didSet { save(watchTrigger.rawValue, "watchTrigger") } }
    var watchSound = true { didSet { save(watchSound, "watchSound") } }
    var watchSaveToHistory = true { didSet { save(watchSaveToHistory, "watchSaveToHistory") } }
    var watchShowOutline = true { didSet { save(watchShowOutline, "watchShowOutline") } }

    // MARK: History
    var historyEnabled = true { didSet { save(historyEnabled, "historyEnabled"); historySyncChanged() } }
    /// History travels between Macs too, while settings sync is on.
    var historySync = true { didSet { save(historySync, "historySync"); historySyncChanged() } }
    var historyMaxCount = Defaults.historyMaxCount { didSet { save(historyMaxCount, "historyMaxCount") } }
    /// 0 keeps entries until the count limit pushes them out.
    var historyMaxDays = 0 { didSet { save(historyMaxDays, "historyMaxDays") } }
    var historySaveImages = true { didSet { save(historySaveImages, "historySaveImages") } }

    // MARK: Shortcuts
    var captureTextHotKey: HotKey? = Defaults.captureTextHotKey { didSet { saveCodable(captureTextHotKey, "captureTextHotKey") } }
    var captureCodeHotKey: HotKey? = Defaults.captureCodeHotKey { didSet { saveCodable(captureCodeHotKey, "captureCodeHotKey") } }
    var captureAgainHotKey: HotKey? = Defaults.captureAgainHotKey { didSet { saveCodable(captureAgainHotKey, "captureAgainHotKey") } }
    var translateHotKey: HotKey? = Defaults.translateHotKey { didSet { saveCodable(translateHotKey, "translateHotKey") } }
    var liveTranslateHotKey: HotKey? = Defaults.liveTranslateHotKey { didSet { saveCodable(liveTranslateHotKey, "liveTranslateHotKey") } }
    var watchHotKey: HotKey? = Defaults.watchHotKey { didSet { saveCodable(watchHotKey, "watchHotKey") } }
    var historyHotKey: HotKey? = Defaults.historyHotKey { didSet { saveCodable(historyHotKey, "historyHotKey") } }

    enum Defaults {
        static let speechRate = 0.5
        static let liveInterval = 1.0
        static let watchInterval = 5.0
        static let historyMaxCount = 1000
        // ⌃⌥⌘ chords, the same family as ClickLens's, on letters it doesn't use.
        static let captureTextHotKey: HotKey? = HotKey(keyCode: 17, modifiers: HotKey.controlOptionCommand, display: "⌃⌥⌘T")
        static let captureCodeHotKey: HotKey? = HotKey(keyCode: 2, modifiers: HotKey.controlOptionCommand, display: "⌃⌥⌘D")
        static let captureAgainHotKey: HotKey? = HotKey(keyCode: 15, modifiers: HotKey.controlOptionCommand, display: "⌃⌥⌘R")
        static let translateHotKey: HotKey? = HotKey(keyCode: 16, modifiers: HotKey.controlOptionCommand, display: "⌃⌥⌘Y")
        static let liveTranslateHotKey: HotKey? = HotKey(keyCode: 32, modifiers: HotKey.controlOptionCommand, display: "⌃⌥⌘U")
        static let watchHotKey: HotKey? = HotKey(keyCode: 13, modifiers: HotKey.controlOptionCommand, display: "⌃⌥⌘W")
        static let historyHotKey: HotKey? = HotKey(keyCode: 4, modifiers: HotKey.controlOptionCommand, display: "⌃⌥⌘H")
    }

    /// Every key this class writes, so a reset can clear them all.
    static let keys = [
        "keepLineBreaks", "accurateRecognition", "languageCorrection", "autoDetectLanguage", "recognitionLanguage",
        "customWords", "openLinks", "playSound", "showNotice", "additiveClipboard", "speakAfterCapture", "speechRate",
        "targetLanguage", "translationCopy", "liveInterval", "liveCoversOriginal",
        "watchInterval", "watchTrigger", "watchSound", "watchSaveToHistory", "watchShowOutline",
        "historyEnabled", "historySync", "historyMaxCount", "historyMaxDays", "historySaveImages",
        "captureTextHotKey", "captureCodeHotKey", "captureAgainHotKey", "translateHotKey", "liveTranslateHotKey",
        "watchHotKey", "historyHotKey",
    ]

    @ObservationIgnored private var loading = false

    private init() { load() }

    /// Puts every setting back to how a new install starts. Where the app appears,
    /// open-at-login and update checks are left alone.
    func resetToDefaults() {
        for key in Self.keys { AppDefaults.store.removeObject(forKey: key) }
        load()
        SettingsSync.shared.localDidChange()
    }

    /// Every setting's current value, in the form UserDefaults stores it, defaults included.
    /// iCloud gets the whole set, so a Mac adopting it never mistakes a setting that is
    /// merely at its default for one that is missing.
    var snapshot: [String: Any] {
        func data<T: Encodable>(_ value: T) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }
        return [
            "keepLineBreaks": keepLineBreaks, "accurateRecognition": accurateRecognition,
            "languageCorrection": languageCorrection, "autoDetectLanguage": autoDetectLanguage,
            "recognitionLanguage": recognitionLanguage, "customWords": customWords, "openLinks": openLinks,
            "playSound": playSound, "showNotice": showNotice, "additiveClipboard": additiveClipboard,
            "speakAfterCapture": speakAfterCapture, "speechRate": speechRate,
            "targetLanguage": targetLanguage, "translationCopy": translationCopy.rawValue,
            "liveInterval": liveInterval, "liveCoversOriginal": liveCoversOriginal,
            "watchInterval": watchInterval, "watchTrigger": watchTrigger.rawValue, "watchSound": watchSound,
            "watchSaveToHistory": watchSaveToHistory, "watchShowOutline": watchShowOutline,
            "historyEnabled": historyEnabled, "historySync": historySync, "historyMaxCount": historyMaxCount, "historyMaxDays": historyMaxDays,
            "historySaveImages": historySaveImages,
            "captureTextHotKey": data(captureTextHotKey), "captureCodeHotKey": data(captureCodeHotKey),
            "captureAgainHotKey": data(captureAgainHotKey), "translateHotKey": data(translateHotKey),
            "liveTranslateHotKey": data(liveTranslateHotKey), "watchHotKey": data(watchHotKey),
            "historyHotKey": data(historyHotKey),
        ]
    }

    /// Re-reads every setting after another Mac's settings were written into UserDefaults.
    func reload() {
        load()
        historySyncChanged(force: true)
    }

    /// History sync follows History and its own switch. Deferred, since it reads Preferences.
    private func historySyncChanged(force: Bool = false) {
        guard !loading || force else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { HistorySync.shared.start() } }
    }

    private func load() {
        loading = true
        defer { loading = false }
        let d = AppDefaults.store
        func double(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) as? Double ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { d.object(forKey: key) as? Int ?? fallback }
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        func string(_ key: String) -> String { d.string(forKey: key) ?? "" }
        func codable<T: Decodable>(_ key: String, _ fallback: T) -> T {
            guard let data = d.data(forKey: key) else { return fallback }
            return (try? JSONDecoder().decode(T.self, from: data)) ?? fallback
        }

        keepLineBreaks = bool("keepLineBreaks", true)
        accurateRecognition = bool("accurateRecognition", true)
        languageCorrection = bool("languageCorrection", true)
        autoDetectLanguage = bool("autoDetectLanguage", true)
        recognitionLanguage = string("recognitionLanguage")
        customWords = string("customWords")
        openLinks = bool("openLinks", false)
        playSound = bool("playSound", true)
        showNotice = bool("showNotice", true)
        additiveClipboard = bool("additiveClipboard", false)
        speakAfterCapture = bool("speakAfterCapture", false)
        speechRate = double("speechRate", Defaults.speechRate)

        targetLanguage = string("targetLanguage")
        translationCopy = TranslationCopy(rawValue: string("translationCopy")) ?? .translation
        liveInterval = double("liveInterval", Defaults.liveInterval)
        liveCoversOriginal = bool("liveCoversOriginal", false)

        watchInterval = double("watchInterval", Defaults.watchInterval)
        watchTrigger = WatchTrigger(rawValue: string("watchTrigger")) ?? .anyChange
        watchSound = bool("watchSound", true)
        watchSaveToHistory = bool("watchSaveToHistory", true)
        watchShowOutline = bool("watchShowOutline", true)

        historyEnabled = bool("historyEnabled", true)
        historySync = bool("historySync", true)
        historyMaxCount = int("historyMaxCount", Defaults.historyMaxCount)
        historyMaxDays = int("historyMaxDays", 0)
        historySaveImages = bool("historySaveImages", true)

        captureTextHotKey = codable("captureTextHotKey", Defaults.captureTextHotKey)
        captureCodeHotKey = codable("captureCodeHotKey", Defaults.captureCodeHotKey)
        captureAgainHotKey = codable("captureAgainHotKey", Defaults.captureAgainHotKey)
        translateHotKey = codable("translateHotKey", Defaults.translateHotKey)
        liveTranslateHotKey = codable("liveTranslateHotKey", Defaults.liveTranslateHotKey)
        watchHotKey = codable("watchHotKey", Defaults.watchHotKey)
        historyHotKey = codable("historyHotKey", Defaults.historyHotKey)
    }

    private func save(_ value: Any, _ key: String) {
        guard !loading else { return }
        store(value as? NSObject, key)
    }

    private func saveCodable<T: Encodable>(_ value: T, _ key: String) {
        guard !loading else { return }
        store((try? JSONEncoder().encode(value)) as NSObject?, key)
    }

    /// Writes only real changes, and reports them for iCloud sync. SwiftUI controls write
    /// their current value back when settings arrive from another Mac; counting those as
    /// edits would send the same settings back and forth between Macs forever.
    private func store(_ value: NSObject?, _ key: String) {
        let defaults = AppDefaults.store
        if let old = defaults.object(forKey: key) as? NSObject, let value, old.isEqual(value) { return }
        defaults.set(value, forKey: key)
        SettingsSync.shared.localDidChange()
    }

    /// The custom words as a list.
    var customWordList: [String] {
        customWords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
