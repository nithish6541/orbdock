import AppKit
import ApplicationServices

/// A borderless, click-through window placed exactly behind the Dock's glass, one level below the Dock.
/// The Dock blurs and tints whatever lies behind it, so painting here colors the Dock itself.
final class DockBackdrop {
    private let window: NSWindow
    private let glowLayer = CALayer()
    private let maskLayer = CALayer()
    private let locator = DockLocator()
    private var locateTimer: Timer?
    private var dockFrame: CGRect?
    private(set) var shown = false

    /// How strongly the glow shows through the Dock's glass.
    private let intensity: Float = 1.0

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.alphaValue = 0
        window.isReleasedWhenClosed = false

        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        glowLayer.contentsGravity = .resize
        glowLayer.magnificationFilter = .linear
        glowLayer.minificationFilter = .linear
        glowLayer.opacity = intensity
        glowLayer.mask = maskLayer
        view.layer!.addSublayer(glowLayer)
        window.contentView = view
    }

    /// Pixel size the glow should be rendered at. Deliberately low: it's soft by nature and scaled up.
    var renderSize: CGSize? {
        guard let f = dockFrame else { return nil }
        return CGSize(width: max(8, (f.width / 4).rounded()), height: max(4, (f.height / 4).rounded()))
    }

    func startTracking() {
        relocate()
        // Faster polling when the Dock slides in and out on its own.
        let autohide = UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
        locateTimer = Timer.scheduledTimer(withTimeInterval: autohide ? 1.0 / 20 : 0.5, repeats: true) { [weak self] _ in
            self?.relocate()
        }
        locateTimer?.tolerance = 0.02
    }

    func setContents(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.contents = image
        CATransaction.commit()
    }

    func fade(in visible: Bool, duration: TimeInterval) {
        guard visible != shown else { return }
        shown = visible
        if visible, dockFrame != nil { window.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !self.shown else { return }
            self.window.orderOut(nil)
        })
    }

    private func relocate() {
        let frame = locator.platterFrame()
        guard frame != dockFrame else { return }
        dockFrame = frame
        guard let frame, NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else {
            window.orderOut(nil)   // hidden Dock, or no Accessibility access yet
            return
        }
        window.setFrame(frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: frame.size)
        glowLayer.frame = bounds
        maskLayer.frame = bounds
        maskLayer.contents = Self.featheredMask(size: frame.size, scale: window.backingScaleFactor)
        CATransaction.commit()
        if shown { window.orderFrontRegardless() }
    }

    /// A rounded rect with softly faded edges, so the color never shows past the Dock's glass.
    private static func featheredMask(size: CGSize, scale: CGFloat) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let inset = DockLocator.edgeInset, feather: CGFloat = 8
        let radius = min(size.height / 2, DockLocator.cornerRadius)
        let steps = 16
        for s in 0..<steps {
            let t = CGFloat(s) / CGFloat(steps - 1)
            let r = CGRect(origin: .zero, size: size).insetBy(dx: inset + feather * t, dy: inset + feather * t)
            guard r.width > 0, r.height > 0 else { break }
            let cr = max(0, min(radius - feather * t, r.height / 2))
            ctx.setFillColor(gray: 1, alpha: t * t * (3 - 2 * t))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: cr, cornerHeight: cr, transform: nil))
            ctx.fillPath()
        }
        return ctx.makeImage()
    }
}

/// Finds the Dock's platter through the Accessibility API.
final class DockLocator {
    /// Tuning for how the backdrop sits under the glass.
    static let edgeInset: CGFloat = 2
    static let cornerRadius: CGFloat = 24

    private var list: AXUIElement?

    /// The Dock's frame in Cocoa screen coordinates, or nil without Accessibility access.
    func platterFrame() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        if list == nil || rect(of: list!) == nil { list = findList() }
        return list.flatMap(rect(of:))
    }

    private func findList() -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        return children(app).first { string($0, kAXRoleAttribute) == kAXListRole }
    }

    private func rect(of el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        // AX uses a top-left origin anchored to the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: pos.x, y: primaryHeight - pos.y - size.height, width: size.width, height: size.height).integral
    }

    private func children(_ el: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    private func string(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
