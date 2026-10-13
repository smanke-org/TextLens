import AppKit

/// Lets the user drag out an area of the screen.
///
/// The screens are photographed first and the selection is drawn over those still
/// pictures, so a menu, tooltip or video frame stays put while you select it. The result
/// carries both the area and its pixels from the still picture.
@MainActor
final class RegionSelector {
    struct Selection {
        let region: ScreenRegion
        /// The selected pixels from the frozen picture.
        let image: CGImage
        /// The selection in global Cocoa coordinates, for placing a result next to it.
        let globalFrame: CGRect
    }

    static let shared = RegionSelector()
    private(set) var isSelecting = false

    private var windows: [SelectionWindow] = []
    private var continuation: CheckedContinuation<Selection?, Never>?
    private var previousApp: NSRunningApplication?

    /// Shows the overlay and waits for a selection; nil if cancelled with Esc.
    func select(prompt: String, tint: NSColor = .systemBlue) async -> Selection? {
        guard !isSelecting else { return nil }
        if !ScreenAccess.granted {
            ScreenAccess.request()
            guard ScreenAccess.granted else { ScreenAccess.explainDenied(); return nil }
        }
        isSelecting = true
        defer { isSelecting = false }

        let images: [CGDirectDisplayID: CGImage]
        do {
            images = try await ScreenGrabber.captureAllScreens()
        } catch {
            NSLog("TextLens: screen capture failed: \(error.localizedDescription)")
            if !ScreenAccess.granted { ScreenAccess.explainDenied() } else { Notice.shared.show(error: "Couldn't capture the screen") }
            return nil
        }

        previousApp = NSWorkspace.shared.frontmostApplication
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for screen in NSScreen.screens {
                guard let image = images[screen.displayID] else { continue }
                let window = SelectionWindow(screen: screen, image: image, prompt: prompt, tint: tint)
                window.onFinish = { [weak self] rect in self?.finish(rect, on: screen, image: image) }
                windows.append(window)
                window.orderFrontRegardless()
            }
            NSApp.activate(ignoringOtherApps: true)
            // Keyboard focus to the window under the pointer, so Esc works at once.
            let pointer = NSEvent.mouseLocation
            (windows.first { NSMouseInRect(pointer, $0.frame, false) } ?? windows.first)?.makeKey()
        }
    }

    /// `rect` is in the screen's view coordinates (origin bottom left), or nil to cancel.
    private func finish(_ rect: CGRect?, on screen: NSScreen, image: CGImage) {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        // Give the keyboard back to the app that had it.
        if let previousApp, previousApp != NSRunningApplication.current { previousApp.activate() }

        guard let rect, rect.width >= 3, rect.height >= 3 else {
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }
        let size = screen.frame.size
        let topLeftRect = CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
        let sx = CGFloat(image.width) / size.width, sy = CGFloat(image.height) / size.height
        let pixels = CGRect(x: topLeftRect.minX * sx, y: topLeftRect.minY * sy,
                            width: topLeftRect.width * sx, height: topLeftRect.height * sy).integral
        guard let cropped = image.cropping(to: pixels) else {
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }
        let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let selection = Selection(region: ScreenRegion(displayID: screen.displayID, rect: topLeftRect),
                                  image: cropped, globalFrame: global)
        continuation?.resume(returning: selection)
        continuation = nil
    }
}

/// One screen's frozen picture with the selection drawn over it.
private final class SelectionWindow: NSWindow {
    var onFinish: ((CGRect?) -> Void)?

    init(screen: NSScreen, image: CGImage, prompt: String, tint: NSColor) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(screen.frame, display: false)
        let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), image: image,
                                 prompt: prompt, tint: tint)
        view.onFinish = { [weak self] rect in self?.onFinish?(rect) }
        contentView = view
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private let image: CGImage
    private let prompt: String
    private let tint: NSColor
    private var start: CGPoint?
    private var current: CGPoint?

    init(frame: CGRect, image: CGImage, prompt: String, tint: NSColor) {
        self.image = image
        self.prompt = prompt
        self.tint = tint
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y)).integral
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(image, in: bounds)

        let dim = NSBezierPath(rect: bounds)
        if let selection { dim.append(NSBezierPath(rect: selection).reversed) }
        NSColor.black.withAlphaComponent(0.32).setFill()
        dim.fill()

        if let selection {
            tint.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1.5
            border.stroke()
            drawLabel("\(Int(selection.width)) × \(Int(selection.height))",
                      at: CGPoint(x: selection.maxX, y: selection.minY), anchorRight: true)
        } else {
            drawPrompt()
        }
    }

    private func drawPrompt() {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: "\(prompt)  ·  Esc to cancel", attributes: attrs)
        let size = text.size()
        let box = CGRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - 120, width: size.width + 28, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        text.draw(at: CGPoint(x: box.minX + 14, y: box.minY + 7))
    }

    private func drawLabel(_ string: String, at point: CGPoint, anchorRight: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: string, attributes: attrs)
        let size = text.size()
        var box = CGRect(x: point.x - (anchorRight ? size.width + 10 : 0), y: point.y - size.height - 10,
                         width: size.width + 10, height: size.height + 4)
        if box.minY < bounds.minY + 2 { box.origin.y = point.y + 4 }
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: box.minX + 5, y: box.minY + 2))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        current = CGPoint(x: min(max(p.x, 0), bounds.maxX), y: min(max(p.y, 0), bounds.maxY))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let rect = selection
        start = nil
        current = nil
        onFinish?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } // Esc
    }

    override func cancelOperation(_ sender: Any?) { onFinish?(nil) }
    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }
}
