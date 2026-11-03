import AppKit
import TextLensKit

/// Everything an agent can do in TextLens. Add a command here and the CLI, `help`, and the MCP
/// tools all get it. Each `run` is on the main actor and calls the same code as the menu bar
/// menu, the History window and the textlens:// actions, so the window updates live.
enum AgentCommands {
    static let all: [AgentCommand] = [
        AgentCommand(name: "status", summary: "Show the version, how many captures history holds (`history`), whether history is on, how many areas are watched, whether live translation or an area selection is under way, and whether Screen Recording is allowed.",
                     example: "textlens status --json", readOnly: true) { _ in
            let prefs = Preferences.shared
            return ["app": AppInfo.name, "version": AppInfo.version,
                    "history": HistoryStore.shared.entries.count, "historyEnabled": prefs.historyEnabled,
                    "pinned": HistoryStore.shared.entries.filter(\.pinned).count,
                    "watches": WatchManager.shared.watches.count, "liveTranslating": LiveTranslator.shared.isRunning,
                    "selecting": RegionSelector.shared.isSelecting, "canCaptureAgain": Capture.shared.lastRegion != nil,
                    "screenRecordingAllowed": ScreenAccess.granted, "translateTo": Translator.shared.defaultTarget.minimalIdentifier,
                    "keepLineBreaks": prefs.keepLineBreaks]
        },

        // MARK: Files

        AgentCommand(name: "text read", summary: "Read the text in a picture or PDF file on this Mac, with the recognition settings from Settings › Capture. Copies nothing and saves nothing. Returns `text` (a PDF's pages joined by blank lines), `pages` (each page's text) and `characters`.",
                     params: [pathParam,
                              .init(name: "line-breaks", kind: .boolean, help: "true keeps the lines as they look, false joins them into paragraphs. Default: the Keep Line Breaks setting"),
                              .init(name: "pages", kind: .integer, help: "read at most this many PDF pages (default and most 50)")],
                     example: "textlens text read ~/Desktop/receipt.png --json", readOnly: true) { args in
            let (url, images) = try pictures(args)
            let keep = try args.bool("line-breaks") ?? Preferences.shared.keepLineBreaks
            var pages: [String] = []
            for image in images {
                pages.append(try await Recognizer.text(in: image, keepLineBreaks: keep, options: .current))
            }
            let text = pages.filter { !$0.isEmpty }.joined(separator: "\n\n")
            return ["path": url.path, "text": text, "characters": text.count, "pages": pages, "found": !text.isEmpty]
        },
        AgentCommand(name: "codes read", summary: "Read the QR and bar codes in a picture or PDF file. Returns `codes` (payload: what the code holds, kind: link, email, phone, sms, wifi, contact, location or text, summary) and `total`. Copies nothing and opens nothing.",
                     params: [pathParam],
                     example: "textlens codes read ~/Downloads/poster.jpg --json", readOnly: true) { args in
            let (url, images) = try pictures(args, pages: 50)
            var seen = Set<String>()
            var payloads: [String] = []
            for image in images {
                for payload in try await Recognizer.codes(in: image) where seen.insert(payload).inserted { payloads.append(payload) }
            }
            return ["path": url.path, "codes": payloads.map { payload -> JSONObject in
                let parsed = CodePayload.parse(payload)
                return ["payload": payload, "kind": kindName(parsed), "summary": parsed.summary]
            }, "total": payloads.count]
        },
        AgentCommand(name: "text translate", summary: "Translate text on this Mac with macOS's own translation; lines and paragraph breaks keep their shape. For the text in a file, run `textlens text read` first. A language pair macOS hasn't downloaded yet gives error code needs_download.",
                     params: [.init(name: "text", required: true, help: "the text to translate"),
                              .init(name: "to", help: "a language code such as fr, de or ja. Default: the language in Settings › Translation (see `textlens languages list`)"),
                              .init(name: "from", help: "the text's language code, when TextLens can't tell it on its own")],
                     example: "textlens text translate --text \"Where is the station?\" --to fr --json", readOnly: true) { args in
            let text = try args.required("text")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentError.usage("--text is empty") }
            let target = try args.string("to").map(language) ?? Translator.shared.defaultTarget
            let source = try args.string("from").map(language)
            do {
                let result = try await Translator.shared.translate(text, to: target, from: source, allowDownload: false)
                return ["translation": result.text, "original": text, "from": result.source.minimalIdentifier,
                        "to": result.target.minimalIdentifier, "sameLanguage": result.sameLanguage]
            } catch let failure as TranslationFailure {
                if failure.message.contains("download") {
                    throw AgentError(code: "needs_download", message: failure.message
                                     + " Ask the person to translate something in that pair once in TextLens (Capture and Translate), which offers the download, then try again", exit: 1)
                }
                let hint = failure.message.contains("couldn't tell") ? " Give --from with its language code" : ""
                throw AgentError.invalid(failure.message + hint)
            }
        },
        AgentCommand(name: "languages list", summary: "List the languages TextLens can translate between (default), or read text in. Returns `languages` (code, name) and `total`.",
                     params: [.init(name: "for", help: "translation (default) or reading")],
                     example: "textlens languages list --for translation --json", readOnly: true) { args in
            let pairs: [(code: String, name: String)]
            switch (args.string("for") ?? "translation").lowercased() {
            case "translation", "translate":
                await Translator.shared.loadLanguages()
                pairs = Translator.shared.languages.map { ($0.minimalIdentifier, Translator.name($0)) }
            case "reading", "read", "recognition":
                pairs = Recognizer.supportedLanguages()
            default:
                throw AgentError.usage("--for must be translation or reading")
            }
            return ["languages": pairs.map { ["code": $0.code, "name": $0.name] as JSONObject }, "total": pairs.count]
        },
        AgentCommand(name: "qr make", summary: "Make a QR code picture of some text or a link, as Make QR Code does, and save it as a PNG file.",
                     params: [.init(name: "text", required: true, help: "what the code holds: text, a link, or a WIFI:, MAILTO: or vCard payload"),
                              .init(name: "to", kind: .path, required: true, help: "a .png file, or a folder to save \"QR Code.png\" in"),
                              .init(name: "size", kind: .integer, help: "its width in points, 64–2048 (default 512; the PNG has twice as many pixels)"),
                              .init(name: "overwrite", kind: .boolean, help: "replace a file that's already there")],
                     example: "textlens qr make --text https://example.com --to ~/Desktop/site.png --json") { args in
            let text = try args.required("text")
            let size = try args.int("size", default: 512)
            guard (64...2048).contains(size) else { throw AgentError.usage("--size must be 64 to 2048") }
            var target = URL(fileURLWithPath: try absolutePath(args.required("to")))
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isFolder), isFolder.boolValue {
                target = target.appending(path: "QR Code.png")
            }
            guard FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) else {
                throw AgentError.notFound("no folder \(target.deletingLastPathComponent().path)")
            }
            if FileManager.default.fileExists(atPath: target.path), try args.bool("overwrite") != true {
                throw AgentError.invalid("\(target.path) is already there. Add --overwrite to replace it, or give another --to")
            }
            guard let image = QRMaker.image(for: text, size: CGFloat(size)),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let png = cg.pngData else {
                throw AgentError.invalid("that's too much text for one QR code")
            }
            try png.write(to: target, options: .atomic)
            return ["path": target.path, "bytes": png.count, "pixels": cg.width]
        },

        // MARK: History

        AgentCommand(name: "history list", summary: "List captures in history, pinned first, then newest, narrowed like the History window's search. Returns `captures` (id, kind, date in UTC, snippet, app, pinned, translated), `total` (every match, whatever --limit is) and `nextOffset` when there are more.",
                     params: [.init(name: "search", help: "words in the text, translation or app name"),
                              .init(name: "kind", help: "text, code, translation or watch"),
                              .init(name: "pinned", kind: .boolean, help: "only pinned captures"),
                              .init(name: "limit", kind: .integer, help: "at most this many (default 50)"),
                              .init(name: "offset", kind: .integer, help: "skip this many, for the next page")],
                     example: "textlens history list --search invoice --kind text --limit 10 --json", readOnly: true) { args in
            var kind: HistoryEntry.Kind?
            if let raw = args.string("kind") {
                guard let value = HistoryEntry.Kind(rawValue: raw.lowercased()) else {
                    throw AgentError.usage("--kind must be one of \(HistoryEntry.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                kind = value
            }
            var entries = HistoryStore.shared.search(args.string("search") ?? "", kind: kind)
            if try args.bool("pinned") == true { entries = entries.filter(\.pinned) }
            return try page(entries, args, key: "captures") { summary($0) }
        },
        AgentCommand(name: "history show", summary: "Show one capture in full: its text, translation and languages, app, date and whether a picture was kept.",
                     params: [idParam],
                     example: "textlens history show 3f2a9c1e --json", readOnly: true) { args in
            detail(try find(args))
        },
        AgentCommand(name: "history add", summary: "Read the text in a picture or PDF file and save it to history as a text capture, with the picture when Settings › History keeps pictures. Leaves the clipboard alone.",
                     params: [pathParam,
                              .init(name: "line-breaks", kind: .boolean, help: "true keeps the lines as they look, false joins them into paragraphs. Default: the Keep Line Breaks setting")],
                     example: "textlens history add ~/Desktop/receipt.png --json") { args in
            guard Preferences.shared.historyEnabled else {
                throw AgentError.invalid("history is off. The person can turn it on in Settings › History")
            }
            let (url, images) = try pictures(args)
            let keep = try args.bool("line-breaks") ?? Preferences.shared.keepLineBreaks
            var pages: [String] = []
            for image in images {
                let text = try await Recognizer.text(in: image, keepLineBreaks: keep, options: .current)
                if !text.isEmpty { pages.append(text) }
            }
            guard !pages.isEmpty else { throw AgentError.invalid("no text found in \(url.path)") }
            guard let entry = HistoryStore.shared.add(kind: .text, text: pages.joined(separator: "\n\n"),
                                                      app: SourceApp(name: nil, bundleID: nil), image: images.first) else {
                throw AgentError.invalid("couldn't save to history")
            }
            return detail(entry)
        },
        AgentCommand(name: "history update", summary: "Pin or unpin a capture. Pinned captures stay on top and are never removed by the history limits.",
                     params: [idParam,
                              .init(name: "pinned", kind: .boolean, required: true, help: "true or false")],
                     example: "textlens history update 3f2a9c1e --pinned true --json") { args in
            let entry = try find(args)
            let pinned = try args.bool("pinned") ?? true
            if entry.pinned != pinned { HistoryStore.shared.togglePin(entry.id) }
            var result = summary(HistoryStore.shared.entry(entry.id) ?? entry)
            result["changed"] = entry.pinned != pinned
            return result
        },
        AgentCommand(name: "history delete", summary: "Delete a capture from history, on every Mac that syncs history. Without --yes it only shows what it would delete.",
                     params: [idParam],
                     example: "textlens history delete 3f2a9c1e --yes --json", destructive: true) { args in
            let entry = try find(args)
            guard args.confirmed else {
                return ["wouldDelete": summary(entry),
                        "hint": "add --yes to delete it. It can't be undone, and it goes from every Mac that syncs history"]
            }
            HistoryStore.shared.delete([entry.id])
            return ["deleted": short(entry.id), "snippet": HistoryQuery.snippet(entry.text, limit: 80)]
        },
        AgentCommand(name: "history open", summary: "Bring up the History window, with a capture selected if you give one.",
                     params: [.init(name: "id", positional: true, help: "a capture to select (the first 8 characters of its id are enough)")],
                     example: "textlens history open 3f2a9c1e --json") { args in
            let id = try args.string("id").map { try find($0).id }
            HistoryWindow.shared.show(selecting: id)
            return ["open": true, "selected": id.map { short($0) as Any } ?? NSNull()]
        },

        // MARK: Watching and capturing

        AgentCommand(name: "watches list", summary: "List the screen areas being watched for changes. Returns `watches` (id, name, alertsOn, everySeconds, alerts, lastAlert, lastError, text: what the area reads now) and `total`.",
                     example: "textlens watches list --json", readOnly: true) { _ in
            let watches = WatchManager.shared.watches
            return ["watches": watches.map { watch -> JSONObject in
                ["id": short(watch.id), "name": watch.name, "alertsOn": watch.summary, "everySeconds": watch.interval,
                 "alerts": watch.changes, "lastAlert": watch.lastChange.map { JSON.date($0) as Any } ?? NSNull(),
                 "lastError": watch.lastError.map { $0 as Any } ?? NSNull(), "text": watch.lastText]
            }, "total": watches.count]
        },
        AgentCommand(name: "watches stop", summary: "Stop watching an area, as Stop Watching in the menu bar menu does, or every area with --all. Starting a watch again takes the person picking the area.",
                     params: [.init(name: "id", positional: true, help: "the watch's id from `textlens watches list`"),
                              .init(name: "all", kind: .boolean, help: "stop every watch")],
                     example: "textlens watches stop 3f2a9c1e --json") { args in
            let manager = WatchManager.shared
            if try args.bool("all") == true {
                guard args.string("id") == nil else { throw AgentError.usage("give an id or --all, not both") }
                let names = manager.watches.map(\.name)
                manager.stopAll()
                return ["stopped": names.count, "names": names]
            }
            guard let prefix = args.string("id")?.lowercased(), !prefix.isEmpty else {
                throw AgentError.usage("missing <id>, or --all. Example: textlens watches stop 3f2a9c1e")
            }
            let matches = manager.watches.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
            guard matches.count == 1 else {
                throw matches.isEmpty ? AgentError.notFound("no watch with id \(prefix). Run `textlens watches list`")
                    : AgentError.invalid("\(matches.count) watches have ids starting \(prefix). Give more of the id")
            }
            manager.stop(matches[0])
            return ["stopped": 1, "names": [matches[0].name]]
        },
        AgentCommand(name: "capture start", summary: "Start a screen capture, as the menu bar menu and the textlens:// links do. Every mode but again waits for the person to drag over an area; again reads the area captured last at once. The text is copied and saved to history: find it with `textlens history list --limit 1`.",
                     params: [.init(name: "mode", required: true, help: "text, again, code (QR or bar code), translate, live-translate (again to stop it) or watch")],
                     example: "textlens capture start --mode text --json") { args in
            try startCapture(args)
        },
    ]

    // MARK: Finding captures

    static let idParam = AgentCommand.Param(name: "id", required: true, positional: true,
                                            help: "the capture's id (the first 8 characters are enough)")
    static let pathParam = AgentCommand.Param(name: "path", kind: .path, required: true, positional: true,
                                              help: "a picture (PNG, JPEG, HEIC, TIFF…) or PDF file")

    static func short(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }

    @MainActor
    static func find(_ args: Args) throws -> HistoryEntry { try find(try args.required("id")) }

    /// The capture whose id starts with `prefix`.
    @MainActor
    static func find(_ prefix: String) throws -> HistoryEntry {
        let key = prefix.lowercased()
        let matches = HistoryStore.shared.entries.filter { $0.id.uuidString.lowercased().hasPrefix(key) }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw AgentError.notFound("no capture with id \(prefix). Run `textlens history list`")
        default: throw AgentError.invalid("\(matches.count) captures have ids starting \(prefix). Give more of the id")
        }
    }

    // MARK: Files

    /// The images in a picture or PDF file named by the `path` param.
    @MainActor
    static func pictures(_ args: Args, pages: Int? = nil) throws -> (URL, [CGImage]) {
        let limit = try pages ?? args.int("pages", default: 50)
        return try pictures(path: try args.required("path"), pages: limit)
    }

    @MainActor
    static func pictures(path: String, pages: Int) throws -> (URL, [CGImage]) {
        guard (1...50).contains(pages) else { throw AgentError.usage("--pages must be 1 to 50") }
        let url = URL(fileURLWithPath: try absolutePath(path))
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            throw AgentError.notFound("nothing at \(url.path)")
        }
        guard !isFolder.boolValue else { throw AgentError.invalid("\(url.path) is a folder. Give one picture or PDF file") }
        let images = Array(Capture.images(in: url).prefix(pages))
        guard !images.isEmpty else {
            throw AgentError.invalid("\(url.path) isn't a picture or PDF TextLens can open (PNG, JPEG, HEIC, TIFF, PDF…)")
        }
        return (url, images)
    }

    // MARK: Results

    static func summary(_ entry: HistoryEntry) -> JSONObject {
        ["id": short(entry.id), "kind": entry.kind.rawValue, "date": JSON.date(entry.date),
         "snippet": HistoryQuery.snippet(entry.text, limit: 100), "app": entry.appName ?? "",
         "pinned": entry.pinned, "translated": entry.translation != nil]
    }

    static func detail(_ entry: HistoryEntry) -> JSONObject {
        var json = summary(entry)
        json["snippet"] = nil
        json["fullID"] = entry.id.uuidString
        json["text"] = entry.text
        json["modified"] = JSON.date(entry.lastModified)
        json["picture"] = entry.thumbnail != nil
        if let bundle = entry.appBundleID { json["appBundleID"] = bundle }
        if let translation = entry.translation { json["translation"] = translation }
        if let from = entry.sourceLanguage { json["from"] = from }
        if let to = entry.targetLanguage { json["to"] = to }
        return json
    }

    static func page<T>(_ all: [T], _ args: Args, key: String, _ json: (T) -> JSONObject) throws -> JSONObject {
        let limit = try args.int("limit", default: 50)
        let offset = try args.int("offset", default: 0)
        guard limit > 0, offset >= 0 else { throw AgentError.usage("--limit must be 1 or more, and --offset 0 or more") }
        let slice = all.dropFirst(offset).prefix(limit)
        var result: JSONObject = [key: slice.map(json), "total": all.count]
        if offset + slice.count < all.count { result["nextOffset"] = offset + slice.count }
        return result
    }

    static func kindName(_ payload: CodePayload) -> String {
        switch payload {
        case .url: "link"
        case .email: "email"
        case .phone: "phone"
        case .sms: "sms"
        case .wifi: "wifi"
        case .contact: "contact"
        case .geo: "location"
        case .text: "text"
        }
    }

    // MARK: Options

    /// MCP clients send paths as they are, so they must already be absolute.
    static func absolutePath(_ path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw AgentError.usage("\"\(path)\" isn't a full path. Give one that starts with / or ~") }
        return expanded
    }

    static func language(_ code: String) throws -> Locale.Language {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" }) else {
            throw AgentError.usage("\"\(code)\" isn't a language code. Use one like fr, de or zh-Hans (see `textlens languages list`)")
        }
        return Locale.Language(identifier: trimmed)
    }

    // MARK: Capturing

    @MainActor
    static func startCapture(_ args: Args) throws -> JSONObject {
        let modes = ["text", "again", "code", "translate", "live-translate", "watch"]
        let mode = try args.required("mode").lowercased()
        guard modes.contains(mode) else { throw AgentError.usage("--mode must be one of \(modes.joined(separator: ", "))") }
        let capture = Capture.shared
        // Asking for Screen Recording from here would put the system prompt up out of nowhere.
        guard ScreenAccess.granted else {
            throw AgentError.invalid("TextLens isn't allowed to record the screen. Ask the person to turn it on in "
                                     + "System Settings › Privacy & Security › Screen & System Audio Recording")
        }
        if mode == "live-translate" && LiveTranslator.shared.isRunning {
            capture.toggleLiveTranslation()
            return ["stopped": "live-translate", "waitsForPerson": false]
        }
        guard !RegionSelector.shared.isSelecting else {
            throw AgentError.busy("the person is already picking an area. Wait for it, then try again")
        }
        switch mode {
        case "again":
            guard capture.lastRegion != nil else { throw AgentError.invalid("nothing to capture again: capture text first") }
            capture.captureAgain()
            return ["started": mode, "waitsForPerson": false, "next": "run `textlens history list --limit 1` in a moment"]
        case "text": capture.captureText()
        case "code": capture.captureCode()
        case "translate": capture.captureAndTranslate()
        case "live-translate": capture.toggleLiveTranslation()
        default: capture.watchRegion()
        }
        let next = ["text": "then run `textlens history list --limit 1`",
                    "code": "TextLens shows what the code holds; then run `textlens history list --kind code --limit 1`",
                    "translate": "TextLens shows the translation; it's saved to history too",
                    "live-translate": "TextLens translates the area as it changes until `textlens capture start --mode live-translate` again",
                    "watch": "the person sets the watch up in a small panel; then run `textlens watches list`"][mode] ?? ""
        return ["started": mode, "waitsForPerson": true, "next": "the person drags over an area; " + next]
    }
}
