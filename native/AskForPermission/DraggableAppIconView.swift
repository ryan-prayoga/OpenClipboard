// Adapted from AskForPermission's Drag/DraggableAppIconView.swift (MIT).
// Upstream: https://github.com/riko2chen/AskForPermission/tree/91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e
import AppKit
import QuartzCore

@MainActor
@objc(OCAppDragIcon)
public final class DraggableAppIconView: NSView, NSDraggingSource {
    private let bundleURL: URL?
    private let appIcon: NSImage
    private let artwork: NSImageView
    private var mouseDownEvent: NSEvent?
    private var hasStartedDrag = false
    private var hovered = false
    private var hoverTracking: NSTrackingArea?

    @objc public var canDrag: Bool { bundleURL != nil }
    @objc public var isInteracting: Bool { mouseDownEvent != nil || hasStartedDrag }
    @objc public var onDrop: ((NSPoint) -> Void)?

    @objc(initWithFrame:bundleURL:)
    public init(frame: NSRect, bundleURL: URL?) {
        self.bundleURL = bundleURL
        let icon = bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSApplication.shared.applicationIconImage
            ?? NSImage(size: NSSize(width: 32, height: 32))
        appIcon = icon

        let info = Bundle.main.infoDictionary ?? [:]
        let hasBundleIcon = info["CFBundleIconFile"] != nil || info["CFBundleIconName"] != nil
        let clipboard = Self.symbol("clipboard.fill", size: 28)
        artwork = NSImageView(image: hasBundleIcon ? icon : clipboard ?? icon)

        super.init(frame: frame)
        artwork.frame = NSRect(x: 16, y: (bounds.height - 26) / 2, width: 26, height: 26)
        artwork.contentTintColor = .controlAccentColor
        artwork.wantsLayer = true
        artwork.setAccessibilityElement(false)
        addSubview(artwork)

        let appName = NSTextField(labelWithString: "OpenClipboard")
        appName.font = .systemFont(ofSize: 14, weight: .semibold)
        appName.frame = NSRect(x: 60, y: 29, width: bounds.width - 108, height: 18)
        appName.setAccessibilityElement(false)
        addSubview(appName)

        let hint = canDrag ? "Seret ke daftar izin" : "Pilih di Pengaturan Sistem"
        let action = NSTextField(labelWithString: hint)
        action.font = .systemFont(ofSize: 12)
        action.textColor = .secondaryLabelColor
        action.frame = NSRect(x: 60, y: 12, width: bounds.width - 108, height: 16)
        action.setAccessibilityElement(false)
        addSubview(action)

        if canDrag, let image = Self.symbol("cursorarrow.motionlines", size: 18) {
            let grip = NSImageView(image: image)
            grip.frame = NSRect(x: bounds.width - 36, y: (bounds.height - 22) / 2, width: 22, height: 22)
            grip.contentTintColor = .controlAccentColor
            grip.setAccessibilityElement(false)
            addSubview(grip)
        }

        if canDrag { toolTip = "Seret OpenClipboard.app ke daftar izin" }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("OpenClipboard")
        setAccessibilityHelp(hint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        let strength = isInteracting ? 0.19 : (hovered ? 0.14 : 0.08)
        accent.withAlphaComponent(strength).setFill()
        tile.fill()
        accent.withAlphaComponent(hovered ? 0.45 : 0.25).setStroke()
        tile.stroke()

        let iconFrame = NSRect(x: 9, y: (bounds.height - 40) / 2, width: 40, height: 40)
        let iconTile = NSBezierPath(roundedRect: iconFrame, xRadius: 10, yRadius: 10)
        accent.withAlphaComponent(0.13).setFill()
        iconTile.fill()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        guard canDrag else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    public override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    public override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    public override func resetCursorRects() {
        if canDrag { addCursorRect(bounds, cursor: .openHand) }
    }

    public override var mouseDownCanMoveWindow: Bool { !canDrag }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { canDrag }
    public override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { canDrag }

    public override func mouseDown(with event: NSEvent) {
        guard canDrag else { return }
        NSApplication.shared.preventWindowOrdering()
        stopHint()
        mouseDownEvent = event
        hasStartedDrag = false
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let bundleURL, !hasStartedDrag else { return }
        let distance = hypot(
            event.locationInWindow.x - down.locationInWindow.x,
            event.locationInWindow.y - down.locationInWindow.y
        )
        guard distance >= 3 else { return }
        hasStartedDrag = true
        startDrag(bundleURL: bundleURL, with: down)
    }

    public override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        needsDisplay = true
    }

    private func startDrag(bundleURL: URL, with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: renderSnapshot() ?? appIcon)

        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        session.draggingFormation = .none
    }

    private func renderSnapshot() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    public func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    public func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // Settings must receive the drop even where the floating guide overlaps it.
        window?.ignoresMouseEvents = true
    }

    public func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let sourceWindow = window
        mouseDownEvent = nil
        hasStartedDrag = false
        needsDisplay = true
        // Keep the guide click-through until its controller identifies the drop target.
        if !operation.isEmpty { onDrop?(screenPoint) }
        sourceWindow?.ignoresMouseEvents = false
    }

    @objc public func playHint() {
        guard canDrag, !isInteracting, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1
        pulse.toValue = 1.08
        pulse.duration = 0.45
        pulse.autoreverses = true
        pulse.repeatCount = 2
        pulse.timingFunction = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)
        artwork.layer?.add(pulse, forKey: "dragHint")
    }

    @objc public func stopHint() {
        artwork.layer?.removeAnimation(forKey: "dragHint")
    }

    private static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
    }
}
