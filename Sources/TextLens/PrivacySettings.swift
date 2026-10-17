import AppKit
import SwiftUI

// MARK: - Privacy

/// What TextLens keeps, what leaves the Mac and what the developer sees (nothing).
struct PrivacySettings: View {
    @State private var sync = SettingsSync.shared
    @State private var prefs = Preferences.shared
    @State private var updater = AutoUpdater.shared
    @State private var screenAccess = ScreenAccess.granted

    private var whatSyncs: String {
        prefs.historyEnabled && prefs.historySync
            ? "your settings, capture history (with pictures) and daily capture counts"
            : "your settings and daily capture counts"
    }

    private var syncSummary: String {
        sync.isEnabled
            ? "Sync is on, so \(whatSyncs) are kept in your own iCloud Drive."
            : "Sync is off, so nothing goes to iCloud. If you turn it on in General, \(whatSyncs) go to your own iCloud Drive."
    }

    var body: some View {
        Form {
            Section("On this Mac") {
                PrivacyPoint("text.viewfinder", "Text recognition, translation and QR codes are handled entirely on your Mac by macOS's built-in frameworks. Nothing is sent to an online service.")
                PrivacyPoint("clock.arrow.circlepath", "Your capture history, including any pictures, is kept in a database on this Mac.")
                PrivacyPoint("rectangle.dashed", "TextLens only looks at the screen when you capture, watch an area or translate live. It reads the picture on your Mac and keeps a small copy in your history only if saving pictures is on.")
            }
            Section {
                PrivacyPoint("icloud", syncSummary)
                PrivacyPoint("lock", "They're encrypted on this Mac with AES-256-GCM before they're uploaded, using a key only your sync passphrase unlocks. The passphrase never leaves your Macs, so neither Apple nor the developer can read them.")
            } header: {
                Text("iCloud")
            }
            Section {
                PrivacyPoint("person.crop.circle.badge.xmark", "TextLens has no account, ads, analytics or tracking. No information about you, your captures or how you use TextLens is ever sent to the developer.")
                #if APPSTORE
                PrivacyPoint("arrow.down.circle", "TextLens makes no connections of its own. The App Store handles updates.")
                #else
                PrivacyPoint("arrow.down.circle", updater.policy == .off
                    ? "Automatic update checks are off, so TextLens connects to the internet only when you choose Check Now."
                    : "The only connection TextLens makes on its own is to GitHub to check for updates. Like any website, GitHub sees your IP address. You can turn update checks off in General.")
                #endif
            } header: {
                Text("The developer")
            }
            Section {
                LabeledContent {
                    Button("Open Privacy & Security") { ScreenAccess.openSettings() }
                } label: {
                    Label(screenAccess ? "Screen Recording is allowed" : "Screen Recording isn't allowed yet",
                          systemImage: screenAccess ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(screenAccess ? Color.secondary : Color.orange)
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("You can remove TextLens's access at any time in System Settings. Capturing then stops working until you allow it again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { screenAccess = ScreenAccess.granted }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenAccess = ScreenAccess.granted
        }
    }
}

/// One statement in the Privacy pane, with a symbol beside it.
struct PrivacyPoint: View {
    let symbol: String
    let text: String

    init(_ symbol: String, _ text: String) {
        self.symbol = symbol
        self.text = text
    }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}
