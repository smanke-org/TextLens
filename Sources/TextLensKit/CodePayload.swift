import Foundation

/// What a scanned QR or bar code holds, worked out from its text so TextLens can offer the
/// right action: open a link, copy a Wi-Fi password, add a contact, and so on.
public enum CodePayload: Equatable, Sendable {
    case url(URL)
    case email(address: String, subject: String?)
    case phone(String)
    case sms(number: String, body: String?)
    case wifi(WiFi)
    case contact(vCard: String, name: String?)
    case geo(latitude: Double, longitude: Double)
    case text(String)

    public struct WiFi: Equatable, Sendable {
        public var ssid: String
        public var password: String?
        /// WPA, WEP, nopass, or empty.
        public var security: String
        public var hidden: Bool

        public init(ssid: String, password: String?, security: String, hidden: Bool) {
            self.ssid = ssid
            self.password = password
            self.security = security
            self.hidden = hidden
        }
    }

    /// A short human description for the result notice.
    public var summary: String {
        switch self {
        case .url(let url): url.absoluteString
        case .email(let address, _): "Email \(address)"
        case .phone(let number): "Phone \(number)"
        case .sms(let number, _): "Text message to \(number)"
        case .wifi(let wifi): "Wi-Fi network “\(wifi.ssid)”"
        case .contact(_, let name): "Contact\(name.map { " \($0)" } ?? "")"
        case .geo(let lat, let lon): "Location \(lat), \(lon)"
        case .text(let text): text
        }
    }

    public static func parse(_ raw: String) -> CodePayload {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        if lower.hasPrefix("wifi:"), let wifi = parseWiFi(text) { return .wifi(wifi) }
        if lower.hasPrefix("begin:vcard") { return .contact(vCard: text, name: vCardName(text)) }
        if lower.hasPrefix("mecard:") { return .contact(vCard: meCardToVCard(text), name: meCardFields(text)["N"]) }
        if lower.hasPrefix("mailto:") {
            let body = String(text.dropFirst(7))
            let parts = body.split(separator: "?", maxSplits: 1)
            let subject = parts.count > 1 ? queryValue(String(parts[1]), "subject") : nil
            return .email(address: String(parts.first ?? ""), subject: subject)
        }
        if lower.hasPrefix("matmsg:") {
            let fields = meCardFields(text, prefixLength: 7)
            return .email(address: fields["TO"] ?? "", subject: fields["SUB"])
        }
        if lower.hasPrefix("tel:") { return .phone(String(text.dropFirst(4))) }
        if lower.hasPrefix("smsto:") || lower.hasPrefix("sms:") {
            let body = String(text.drop(while: { $0 != ":" }).dropFirst())
            let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
            return .sms(number: parts.first ?? "", body: parts.count > 1 ? parts[1] : nil)
        }
        if lower.hasPrefix("geo:") {
            let coords = text.dropFirst(4).split(separator: "?")[0].split(separator: ",")
            if coords.count >= 2, let lat = Double(coords[0]), let lon = Double(coords[1]) {
                return .geo(latitude: lat, longitude: lon)
            }
        }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), url.host != nil {
            return .url(url)
        }
        // A bare domain such as "example.com/page" is still meant as a link.
        if !text.contains(" "), !text.contains("\n"), text.contains("."),
           let url = URL(string: "https://" + text), let host = url.host, host.contains("."),
           host.split(separator: ".").last.map({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }) == true {
            return .url(url)
        }
        return .text(text)
    }

    // MARK: Wi-Fi

    /// `WIFI:T:WPA;S:Home;P:secret;H:false;;` with `\` escaping `;,:"\`.
    static func parseWiFi(_ text: String) -> WiFi? {
        let fields = meCardFields(text, prefixLength: 5)
        guard let ssid = fields["S"], !ssid.isEmpty else { return nil }
        return WiFi(ssid: ssid, password: fields["P"].flatMap { $0.isEmpty ? nil : $0 },
                    security: fields["T"] ?? "", hidden: fields["H"]?.lowercased() == "true")
    }

    /// Builds the text for a Wi-Fi QR code that phones understand.
    public static func wifiCode(ssid: String, password: String, security: String, hidden: Bool) -> String {
        func escape(_ s: String) -> String {
            var out = ""
            for c in s {
                if "\\;,:\"".contains(c) { out.append("\\") }
                out.append(c)
            }
            return out
        }
        let type = password.isEmpty ? "nopass" : security
        var code = "WIFI:T:\(type);S:\(escape(ssid));"
        if !password.isEmpty { code += "P:\(escape(password));" }
        if hidden { code += "H:true;" }
        return code + ";"
    }

    /// Splits `KEY:value;KEY:value;` fields, honoring backslash escapes.
    static func meCardFields(_ text: String, prefixLength: Int = 7) -> [String: String] {
        var fields: [String: String] = [:]
        var current = ""
        var escaped = false
        func flush() {
            guard let colon = current.firstIndex(of: ":") else { current = ""; return }
            let key = current[..<colon].uppercased()
            let value = String(current[current.index(after: colon)...])
            if fields[key] == nil { fields[key] = value }
            current = ""
        }
        for c in text.dropFirst(prefixLength) {
            if escaped { current.append(c); escaped = false; continue }
            switch c {
            case "\\": escaped = true
            case ";": flush()
            default: current.append(c)
            }
        }
        if !current.isEmpty { flush() }
        return fields
    }

    static func meCardToVCard(_ text: String) -> String {
        let f = meCardFields(text)
        var lines = ["BEGIN:VCARD", "VERSION:3.0"]
        if let n = f["N"] {
            // MECARD writes "Last,First".
            let parts = n.split(separator: ",", maxSplits: 1).map(String.init)
            lines.append("N:\(parts.first ?? "");\(parts.count > 1 ? parts[1] : "");;;")
            lines.append("FN:\(parts.reversed().joined(separator: " "))")
        }
        if let tel = f["TEL"] { lines.append("TEL:\(tel)") }
        if let email = f["EMAIL"] { lines.append("EMAIL:\(email)") }
        if let url = f["URL"] { lines.append("URL:\(url)") }
        if let adr = f["ADR"] { lines.append("ADR:;;\(adr);;;;") }
        if let org = f["ORG"] { lines.append("ORG:\(org)") }
        lines.append("END:VCARD")
        return lines.joined(separator: "\r\n")
    }

    static func vCardName(_ text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("FN:") || trimmed.uppercased().hasPrefix("FN;") {
                return trimmed.split(separator: ":", maxSplits: 1).last.map(String.init)
            }
        }
        return nil
    }

    static func queryValue(_ query: String, _ name: String) -> String? {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.first?.lowercased() == name, kv.count == 2 {
                return String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
        return nil
    }
}
