import AppKit
import ScreenCaptureKit

/// The Screen Recording permission ScreenCaptureKit needs.
enum ScreenAccess {
    static var granted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards macOS only lists the app in
    /// System Settings, so the caller should offer to open it.
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Explains what to do when capture is refused. Only called from something the user did.
    @MainActor
    static func explainDenied() {
        let alert = NSAlert()
        alert.messageText = "TextLens needs Screen Recording access"
        alert.informativeText = "TextLens reads text from a picture of your screen, which macOS only allows once you switch TextLens on in System Settings › Privacy & Security › Screen & System Audio Recording. Nothing is recorded or sent anywhere; the picture is read on your Mac and thrown away."
        alert.addButton(withTitle: "Not Now")
        let open = alert.addButton(withTitle: "Open System Settings")
        open.keyEquivalent = ""
        alert.layout()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
        if alert.runModal() == .alertSecondButtonReturn { openSettings() }
    }
}

struct GrabError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Pictures of the screen through ScreenCaptureKit, always leaving out TextLens's own
/// windows: the selection overlay, an outline around a watched region, and above all a
/// live translation drawn over the text it is reading.
enum ScreenGrabber {
    /// A picture of every display, keyed by display ID, at full pixel resolution.
    static func captureAllScreens() async throws -> [CGDirectDisplayID: CGImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let own = content.applications.filter { $0.processID == getpid() }
        var images: [CGDirectDisplayID: CGImage] = [:]
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(display.frame.width * scale)
            config.height = Int(display.frame.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            images[display.displayID] = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
        return images
    }

    /// Repeated pictures of one area, reusing the display lookup between frames.
    final class RegionCamera: @unchecked Sendable {
        let displayID: CGDirectDisplayID
        /// The area in the display's own points, origin at its top left.
        let sourceRect: CGRect
        private var filter: SCContentFilter?

        init(displayID: CGDirectDisplayID, sourceRect: CGRect) {
            self.displayID = displayID
            self.sourceRect = sourceRect
        }

        func capture() async throws -> CGImage {
            if filter == nil { filter = try await Self.makeFilter(displayID) }
            guard let filter else { throw GrabError(message: "That display is no longer connected.") }
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.sourceRect = sourceRect
            config.width = max(1, Int(sourceRect.width * scale))
            config.height = max(1, Int(sourceRect.height * scale))
            config.showsCursor = false
            config.captureResolution = .best
            do {
                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                // Displays get rearranged and apps relaunch; look everything up again next time.
                self.filter = nil
                throw error
            }
        }

        private static func makeFilter(_ displayID: CGDirectDisplayID) async throws -> SCContentFilter? {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let own = content.applications.filter { $0.processID == getpid() }
            return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        }
    }
}

/// An area of one screen the user picked.
struct ScreenRegion: Codable, Equatable {
    var displayID: CGDirectDisplayID
    /// In the display's points, origin at its top left (ScreenCaptureKit's convention).
    var rect: CGRect

    @MainActor var screen: NSScreen? { NSScreen.screens.first { $0.displayID == displayID } }

    /// The same area in Cocoa's global coordinates (origin at the bottom left of the main
    /// screen), for placing windows around it.
    @MainActor var globalFrame: CGRect? {
        guard let screen else { return nil }
        return CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    func camera() -> ScreenGrabber.RegionCamera {
        ScreenGrabber.RegionCamera(displayID: displayID, sourceRect: rect)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

extension CGImage {
    /// Vision reads small text far better when it is a few dozen pixels tall, so a
    /// one-line selection is enlarged before reading.
    func upscaledForReading(minHeight: Int = 120) -> CGImage {
        guard height < minHeight else { return self }
        let factor = min(4, Int(ceil(Double(minHeight) / Double(max(height, 1)))))
        guard factor > 1,
              let context = CGContext(data: nil, width: width * factor, height: height * factor, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width * factor, height: height * factor))
        context.draw(self, in: CGRect(x: 0, y: 0, width: width * factor, height: height * factor))
        return context.makeImage() ?? self
    }

    /// A copy no larger than `maxSide` pixels on its longer side, for history thumbnails.
    func thumbnail(maxSide: Int = 640) -> CGImage {
        let longest = max(width, height)
        guard longest > maxSide else { return self }
        let scale = Double(maxSide) / Double(longest)
        let w = max(1, Int(Double(width) * scale)), h = max(1, Int(Double(height) * scale))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? self
    }

    var pngData: Data? {
        NSBitmapImageRep(cgImage: self).representation(using: .png, properties: [:])
    }
}
