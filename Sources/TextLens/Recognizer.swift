import AppKit
import NaturalLanguage
import PDFKit
import TextLensKit
import Vision

/// Text and code reading with Apple's Vision framework, entirely on this Mac.
enum Recognizer {
    struct Options: Sendable {
        var accurate = true
        var languageCorrection = true
        var autoDetectLanguage = true
        var languages: [String] = []
        var customWords: [String] = []

        @MainActor static var current: Options {
            let p = Preferences.shared
            return Options(accurate: p.accurateRecognition, languageCorrection: p.languageCorrection,
                           autoDetectLanguage: p.autoDetectLanguage,
                           languages: p.recognitionLanguage.isEmpty ? [] : [p.recognitionLanguage],
                           customWords: p.customWordList)
        }
    }

    /// Every line of text in the image, with where it sits.
    static func lines(in image: CGImage, options: Options) async throws -> [RecognizedLine] {
        let source = image.upscaledForReading()
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = options.accurate ? .accurate : .fast
            request.usesLanguageCorrection = options.languageCorrection
            request.automaticallyDetectsLanguage = options.autoDetectLanguage && options.languages.isEmpty
            if !options.languages.isEmpty { request.recognitionLanguages = options.languages }
            if !options.customWords.isEmpty { request.customWords = options.customWords }
            let handler = VNImageRequestHandler(cgImage: source, options: [:])
            try handler.perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return RecognizedLine(text: text, box: observation.boundingBox)
            }
        }.value
    }

    /// The image's text, laid out as it looked.
    static func text(in image: CGImage, keepLineBreaks: Bool, options: Options) async throws -> String {
        TextAssembler.assemble(try await lines(in: image, options: options), keepLineBreaks: keepLineBreaks)
    }

    /// The contents of every QR and bar code in the image, in reading order.
    static func codes(in image: CGImage) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            func detect(_ image: CGImage) throws -> [VNBarcodeObservation] {
                let request = VNDetectBarcodesRequest()
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                return request.results ?? []
            }
            var results = try detect(image)
            // Small codes on screen read better enlarged.
            if results.isEmpty, image.width < 600 {
                results = try detect(image.upscaledForReading(minHeight: min(image.height * 3, 900)))
            }
            var seen = Set<String>()
            return results
                .sorted { ($0.boundingBox.maxY, -$0.boundingBox.minX) > ($1.boundingBox.maxY, -$1.boundingBox.minX) }
                .compactMap(\.payloadStringValue)
                .filter { seen.insert($0).inserted }
        }.value
    }

    /// The languages Vision can read, as (code, name) pairs.
    static func supportedLanguages() -> [(code: String, name: String)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let codes = (try? request.supportedRecognitionLanguages()) ?? []
        return codes.map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }
    }

    /// The dominant language of some text, if NaturalLanguage can tell.
    static func language(of text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    /// Pages of a PDF as images, at twice their point size.
    static func pageImages(ofPDF url: URL, limit: Int = 50) -> [CGImage] {
        guard let document = PDFDocument(url: url) else { return [] }
        var images: [CGImage] = []
        for index in 0..<min(document.pageCount, limit) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2
            let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            if let image = context.makeImage() { images.append(image) }
        }
        return images
    }
}
