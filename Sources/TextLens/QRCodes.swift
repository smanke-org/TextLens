import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import TextLensKit
import UniformTypeIdentifiers

/// What a scan found, with an action that fits each kind of code.
@MainActor
final class CodeResultPanel {
    static let shared = CodeResultPanel()
    private var panel: FloatingPanel?

    func show(_ payloads: [String], near anchor: CGRect?) {
        panel?.close()
        let panel = FloatingPanel(title: payloads.count == 1 ? "Code Found" : "\(payloads.count) Codes Found",
                                  size: CGSize(width: 400, height: 10), resizable: false)
        let view = CodeResultView(payloads: payloads) { [weak panel] in panel?.close() }
        panel.host(view)
        panel.place(near: anchor)
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

private struct CodeResultView: View {
    let payloads: [String]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(payloads.enumerated()), id: \.offset) { _, raw in
                CodeRow(raw: raw, close: close)
                if raw != payloads.last { Divider() }
            }
        }
        .padding(16)
        .padding(.top, 14)
        .frame(width: 400)
    }
}

private struct CodeRow: View {
    let raw: String
    let close: () -> Void
    private var payload: CodePayload { CodePayload.parse(raw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            Text(detail)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("Copy") { copy(raw, "Copied") }
                actions
            }
            .controlSize(.small)
        }
    }

    private var title: String {
        switch payload {
        case .url: "Link"
        case .email: "Email"
        case .phone: "Phone Number"
        case .sms: "Text Message"
        case .wifi: "Wi-Fi Network"
        case .contact: "Contact"
        case .geo: "Location"
        case .text: "Text"
        }
    }

    private var symbol: String {
        switch payload {
        case .url: "link"
        case .email: "envelope"
        case .phone: "phone"
        case .sms: "message"
        case .wifi: "wifi"
        case .contact: "person.crop.circle"
        case .geo: "mappin.and.ellipse"
        case .text: "text.alignleft"
        }
    }

    private var detail: String {
        switch payload {
        case .wifi(let wifi):
            var lines = ["Network: \(wifi.ssid)"]
            if let password = wifi.password { lines.append("Password: \(password)") }
            if !wifi.security.isEmpty && wifi.security.lowercased() != "nopass" { lines.append("Security: \(wifi.security)") }
            if wifi.hidden { lines.append("Hidden network") }
            return lines.joined(separator: "\n")
        case .contact(_, let name):
            return name ?? raw
        case .email(let address, let subject):
            return subject.map { "\(address)\nSubject: \($0)" } ?? address
        default:
            return payload.summary
        }
    }

    @ViewBuilder private var actions: some View {
        switch payload {
        case .url(let url):
            Button("Open Link") { open(url) }.keyboardShortcut(.defaultAction)
        case .email(let address, let subject):
            Button("New Email") {
                var parts = URLComponents()
                parts.scheme = "mailto"
                parts.path = address
                if let subject { parts.queryItems = [URLQueryItem(name: "subject", value: subject)] }
                if let url = parts.url { open(url) }
            }
        case .phone(let number):
            Button("Call") { if let url = URL(string: "tel:\(number.filter { !$0.isWhitespace })") { open(url) } }
        case .sms(let number, _):
            Button("Message") { if let url = URL(string: "sms:\(number.filter { !$0.isWhitespace })") { open(url) } }
        case .wifi(let wifi):
            if let password = wifi.password {
                Button("Copy Password") { copy(password, "Wi-Fi password copied") }.keyboardShortcut(.defaultAction)
            }
        case .contact(let card, let name):
            Button("Add to Contacts") {
                let file = FileManager.default.temporaryDirectory.appending(path: "\(name ?? "Contact").vcf")
                do {
                    try card.write(to: file, atomically: true, encoding: .utf8)
                    NSWorkspace.shared.open(file)
                    close()
                } catch {
                    Notice.shared.show(error: "Couldn't make the contact card")
                }
            }
        case .geo(let lat, let lon):
            Button("Show in Maps") { if let url = URL(string: "maps://?ll=\(lat),\(lon)&q=\(lat),\(lon)") { open(url) } }
        case .text:
            EmptyView()
        }
    }

    private func copy(_ text: String, _ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Notice.shared.show(message)
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
        close()
    }
}

// MARK: - Making QR codes

enum QRMaker {
    /// A crisp QR code image of `text`, `size` points square (drawn at 2× for Retina).
    static func image(for text: String, size: CGFloat = 512, correction: String = "M") -> NSImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correction
        guard let output = filter.outputImage else { return nil }
        // Integer scaling keeps the modules sharp.
        let scale = max(1, floor(size * 2 / output.extent.width))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width / 2, height: scaled.extent.height / 2))
    }
}

@MainActor
final class QRMakerWindow: NSObject, NSWindowDelegate {
    static let shared = QRMakerWindow()
    private var window: NSWindow?
    private let model = QRMakerModel()

    func show(text: String? = nil) {
        if let text { model.kind = .text; model.text = text }
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: QRMakerView(model: model)))
            window.title = "Make QR Code"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@Observable
@MainActor
final class QRMakerModel {
    enum Kind: String, CaseIterable { case text = "Text or Link", wifi = "Wi-Fi Network" }
    var kind = Kind.text
    var text = ""
    var ssid = ""
    var password = ""
    var security = "WPA"
    var hidden = false
    var correction = "M"

    var content: String {
        switch kind {
        case .text: text
        case .wifi: ssid.isEmpty ? "" : CodePayload.wifiCode(ssid: ssid, password: password, security: security, hidden: hidden)
        }
    }
}

private struct QRMakerView: View {
    @Bindable var model: QRMakerModel

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Make a code for", selection: $model.kind) {
                    ForEach(QRMakerModel.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch model.kind {
                case .text:
                    TextEditor(text: $model.text)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                        .overlay(alignment: .topLeading) {
                            if model.text.isEmpty {
                                Text("Type or paste text or a link").foregroundStyle(.tertiary).padding(11).allowsHitTesting(false)
                            }
                        }
                        .frame(height: 150)
                case .wifi:
                    Form {
                        TextField("Network", text: $model.ssid)
                        SecureField("Password", text: $model.password)
                        Picker("Security", selection: $model.security) {
                            Text("WPA/WPA2/WPA3").tag("WPA")
                            Text("WEP").tag("WEP")
                        }
                        .disabled(model.password.isEmpty)
                        Toggle("Hidden network", isOn: $model.hidden)
                    }
                    .frame(height: 150, alignment: .top)
                }
                Picker("Error correction", selection: $model.correction) {
                    Text("Low").tag("L"); Text("Medium").tag("M"); Text("High").tag("Q"); Text("Highest").tag("H")
                }
                .fixedSize()
                .help("Higher correction still scans when part of the code is covered or damaged, but makes a denser code.")
                Text("Drag the code into any app, or copy or save it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 320)
            .padding(.top, 12)

            VStack(spacing: 12) {
                let image = QRMaker.image(for: model.content, correction: model.correction)
                Group {
                    if let image {
                        Image(nsImage: image).interpolation(.none).resizable()
                            .onDrag { NSItemProvider(object: image) }
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                            .overlay(Image(systemName: "qrcode").font(.system(size: 50)).foregroundStyle(.tertiary))
                    }
                }
                .frame(width: 220, height: 220)
                .padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    Button("Copy Image") {
                        if let image { Clipboard.copyImage(image); Notice.shared.show("QR code copied") }
                    }
                    Button("Save…") { if let image { save(image) } }
                }
                .disabled(image == nil)
                if model.content.utf8.count > 2_000 {
                    Text("That's a lot of text for one code; phones may struggle to scan it.")
                        .font(.caption).foregroundStyle(.orange).frame(width: 240)
                }
            }
            .padding(.top, 12)
        }
        .padding(20)
    }

    private func save(_ image: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "QR Code.png"
        guard panel.runModal() == .OK, let url = panel.url,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let data = cg.pngData else { return }
        do { try data.write(to: url) } catch { Notice.shared.show(error: "Couldn't save the image") }
    }
}
