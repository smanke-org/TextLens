import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A keyboard shortcut: a key code plus Carbon modifier flags, and how to show it.
struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// Builds one from a key press, if it has at least one of ⌘ ⌥ ⌃ — a bare key would
    /// steal ordinary typing from every app.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = Self.carbon(flags)
        display = Self.symbols(flags) + Self.name(for: event)
    }

    /// Builds one from a key code and Carbon modifiers (ShortcutsLens's Change Shortcut), named
    /// the way a key press would be in the current keyboard layout. Nil without ⌘ ⌥ or ⌃.
    init?(keyCode: Int, carbonModifiers: Int) {
        let mods = UInt32(carbonModifiers) & UInt32(controlKey | optionKey | shiftKey | cmdKey)
        guard mods & UInt32(controlKey | optionKey | cmdKey) != 0, (0...127).contains(keyCode) else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if mods & UInt32(controlKey) != 0 { flags.insert(.control) }
        if mods & UInt32(optionKey) != 0 { flags.insert(.option) }
        if mods & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if mods & UInt32(cmdKey) != 0 { flags.insert(.command) }
        self.keyCode = UInt32(keyCode)
        modifiers = mods
        display = Self.symbols(flags) + Self.name(keyCode: keyCode, characters: Self.layoutCharacter(keyCode))
    }

    /// Whether a key press is this shortcut.
    func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        UInt32(keyCode) == self.keyCode
            && Self.carbon(flags.intersection([.command, .option, .control, .shift])) == modifiers
    }

    /// For showing the shortcut beside a menu item.
    var menuKeyEquivalent: (key: String, mask: NSEvent.ModifierFlags) {
        var mask: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        let key = display.drop(while: { "⌃⌥⇧⌘".contains($0) }).lowercased()
        return (key.count == 1 ? key : "", mask)
    }

    private static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    private static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    private static func name(for event: NSEvent) -> String {
        name(keyCode: Int(event.keyCode), characters: event.charactersIgnoringModifiers)
    }

    private static func name(keyCode code: Int, characters: String?) -> String {
        if let f = fKeys[code] { return "F\(f)" }
        switch code {
        case kVK_Return: return "↩"
        case kVK_Space: return "Space"
        case kVK_Escape: return "⎋"
        case kVK_Tab: return "⇥"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: return (characters ?? "?").uppercased()
        }
    }

    /// What the key types with no modifiers in the current layout ("t" for kVK_ANSI_T on QWERTY).
    private static func layoutCharacter(_ keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    /// Key code → F-key number. A table, not a range: the codes are scattered (F1 is 122,
    /// F20 is 90).
    private static let fKeys: [Int: Int] = {
        let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return Dictionary(uniqueKeysWithValues: codes.enumerated().map { ($1, $0 + 1) })
    }()
}

/// System-wide shortcuts through Carbon's RegisterEventHotKey: works from a menu bar app
/// and needs no permission.
@MainActor
final class HotKeyCenter {
    enum Action: UInt32, CaseIterable {
        case captureText = 1
        case captureCode = 2
        case captureAgain = 3
        case translate = 4
        case liveTranslate = 5
        case watch = 6
        case history = 7

        @MainActor var hotKey: HotKey? {
            let prefs = Preferences.shared
            switch self {
            case .captureText: return prefs.captureTextHotKey
            case .captureCode: return prefs.captureCodeHotKey
            case .captureAgain: return prefs.captureAgainHotKey
            case .translate: return prefs.translateHotKey
            case .liveTranslate: return prefs.liveTranslateHotKey
            case .watch: return prefs.watchHotKey
            case .history: return prefs.historyHotKey
            }
        }

        /// As the Shortcuts settings name it.
        var title: String {
            switch self {
            case .captureText: return "Capture text"
            case .captureCode: return "Read QR or bar code"
            case .captureAgain: return "Capture the same area again"
            case .translate: return "Capture and translate"
            case .liveTranslate: return "Live translate (start/stop)"
            case .watch: return "Watch an area"
            case .history: return "Show history"
            }
        }
    }

    static let shared = HotKeyCenter()
    var perform: ((Action) -> Void)?
    private var refs: [Action: EventHotKeyRef] = [:]
    private var installed = false

    /// Registers the shortcuts in Preferences, replacing earlier registrations.
    func apply() {
        installHandlerOnce()
        unregisterAll()
        for action in Action.allCases {
            guard let key = action.hotKey else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5458_4C53), id: action.rawValue) // "TXLS"
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
            } else {
                NSLog("TextLens: shortcut \(key.display) for \(action) not registered (\(status)), probably taken by another app")
            }
        }
        ShortcutsLensReport.publish()
    }

    /// For ShortcutsLens: the shortcuts that registered, in Settings order.
    var reportedShortcuts: [ShortcutsLensReport.Shortcut] {
        Action.allCases.compactMap { action in
            guard refs[action] != nil, let key = action.hotKey else { return nil }
            return .init(id: "\(action)", title: action.title, keyCode: Int(key.keyCode), carbonModifiers: Int(key.modifiers))
        }
    }

    /// ShortcutsLens's Change Shortcut: saves the keys as the Settings recorder does (so Settings
    /// shows them and sync carries them) and registers again. Nil when done, or why not.
    func change(id: String, keyCode: Int, carbonModifiers: Int) -> String? {
        guard let action = Action.allCases.first(where: { "\($0)" == id }) else { return "TextLens has no shortcut called \(id)." }
        guard let key = HotKey(keyCode: keyCode, carbonModifiers: carbonModifiers) else {
            return "TextLens shortcuts need ⌘, ⌥ or ⌃."
        }
        if let other = Action.allCases.first(where: { $0 != action && $0.hotKey?.keyCode == key.keyCode && $0.hotKey?.modifiers == key.modifiers }) {
            return "TextLens already uses \(key.display) for \(other.title)."
        }
        let previous = action.hotKey
        save(key, for: action)
        apply()
        guard refs[action] == nil else { return nil }
        // Taken by another app: keep the old keys rather than leave the shortcut dead.
        save(previous, for: action)
        apply()
        return "\(key.display) is taken by another app, so TextLens kept \(previous?.display ?? "no shortcut")."
    }

    private func save(_ key: HotKey?, for action: Action) {
        let prefs = Preferences.shared
        switch action {
        case .captureText: prefs.captureTextHotKey = key
        case .captureCode: prefs.captureCodeHotKey = key
        case .captureAgain: prefs.captureAgainHotKey = key
        case .translate: prefs.translateHotKey = key
        case .liveTranslate: prefs.liveTranslateHotKey = key
        case .watch: prefs.watchHotKey = key
        case .history: prefs.historyHotKey = key
        }
    }

    /// Whether a key press is one of TextLens's own shortcuts.
    func isOwnHotKey(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        Action.allCases.contains { $0.hotKey?.matches(keyCode: keyCode, flags: flags) == true }
    }

    /// While a shortcut is being recorded, the current ones must not fire.
    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    private func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
    }

    fileprivate func fire(_ id: UInt32) {
        guard let action = Action(rawValue: id) else { return }
        perform?(action)
    }
}

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let value = id.id
    // Carbon delivers hot keys on the main thread's event loop.
    MainActor.assumeIsolated { HotKeyCenter.shared.fire(value) }
    return noErr
}

/// Click, then press a shortcut. Esc cancels, Delete clears.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var hotKey: HotKey?

    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton()
        view.onChange = { hotKey = $0 }
        view.hotKey = hotKey
        return view
    }

    func updateNSView(_ view: RecorderButton, context: Context) {
        view.onChange = { hotKey = $0 }
        view.hotKey = hotKey
    }

    final class RecorderButton: NSButton {
        var onChange: ((HotKey?) -> Void)?
        var hotKey: HotKey? { didSet { refresh() } }
        private var recording = false { didSet { refresh() } }
        private var monitor: Any?

        override init(frame: NSRect) {
            super.init(frame: frame)
            bezelStyle = .rounded
            target = self
            action = #selector(toggle)
            refresh()
        }

        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: NSSize { NSSize(width: 140, height: super.intrinsicContentSize.height) }

        private func refresh() {
            title = recording ? "Press a shortcut…" : (hotKey?.display ?? "Click to set")
        }

        @objc private func toggle() {
            recording ? stop() : start()
        }

        private func start() {
            recording = true
            HotKeyCenter.shared.unregisterAll()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                switch Int(event.keyCode) {
                case kVK_Escape:
                    self.stop()
                case kVK_Delete, kVK_ForwardDelete:
                    self.hotKey = nil
                    self.onChange?(nil)
                    self.stop()
                default:
                    guard let key = HotKey(event: event) else { NSSound.beep(); return nil }
                    self.hotKey = key
                    self.onChange?(key)
                    self.stop()
                }
                return nil
            }
        }

        private func stop() {
            recording = false
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            // The binding writes Preferences synchronously, so this sees the new key.
            HotKeyCenter.shared.apply()
        }
    }
}
