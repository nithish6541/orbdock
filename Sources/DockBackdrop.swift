import AppKit
import ApplicationServices

/// A borderless, click-through window along the Dock's screen edge, one level below the Dock.
///
/// It shows the glow twice from one image: as a soft floor of light spanning the whole edge of the screen,
/// fading out before the top of the Dock's reserved area so it has no visible edge, and at full strength
/// behind the Dock's glass, aligned pixel for pixel. The Dock reads as the brightest part of one light
/// rather than a colored object sitting on the screen.
final class DockBackdrop {
    private enum Edge { case bottom, left, right }

    private let window: NSWindow
    private let floorLayer = CALayer()
    private let floorMask = CAGradientLayer()
    private let pillLayer = CALayer()
    private let pillMask = CALayer()
    private let locator = DockLocator()
    private var locateTimer: Timer?
    private var dockFrame: CGRect?
    private var floorFrame: CGRect?
    private(set) var shown = false

    /// Strength of the floor light at the screen edge; it fades to nothing away from the edge.
    private let floorIntensity: Float = 0.7
    /// Strength behind the Dock's glass. A little brighter than the floor, but not so much it becomes an object.
    private let dockIntensity: Float = 0.85

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
        for layer in [floorLayer, pillLayer] {
            layer.contentsGravity = .resize
            layer.magnificationFilter = .linear
            layer.minificationFilter = .linear
            view.layer!.addSublayer(layer)
        }
        floorMask.colors = [CGColor(gray: 0, alpha: CGFloat(floorIntensity)),
                            CGColor(gray: 0, alpha: CGFloat(floorIntensity) * 0.4),
                            CGColor(gray: 0, alpha: 0)]
        floorMask.locations = [0, 0.45, 1]
        floorLayer.mask = floorMask
        pillLayer.mask = pillMask
        pillLayer.opacity = dockIntensity
        window.contentView = view
    }

    /// Pixel size the glow should be rendered at. Deliberately low: it's soft by nature and scaled up.
    var renderSize: CGSize? {
        guard let f = floorFrame else { return nil }
        return CGSize(width: max(8, (f.width / 5).rounded()), height: max(4, (f.height / 5).rounded()))
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
        floorLayer.contents = image
        pillLayer.contents = image
        CATransaction.commit()
    }

    func fade(in visible: Bool, duration: TimeInterval) {
        guard visible != shown else { return }
        shown = visible
        if visible, floorFrame != nil { window.orderFrontRegardless() }
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
        let dock = locator.platterFrame()
        guard dock != dockFrame else { return }
        dockFrame = dock
        guard let dock, let screen = NSScreen.screens.first(where: { $0.frame.intersects(dock) }) else {
            floorFrame = nil
            window.orderOut(nil)   // hidden Dock, or no Accessibility access yet
            return
        }

        let (floor, edge) = Self.floor(for: dock, on: screen)
        floorFrame = floor
        window.setFrame(floor, display: false)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: floor.size)
        floorLayer.frame = bounds
        floorMask.frame = bounds
        switch edge {
        case .bottom: floorMask.startPoint = CGPoint(x: 0.5, y: 0); floorMask.endPoint = CGPoint(x: 0.5, y: 1)
        case .left: floorMask.startPoint = CGPoint(x: 0, y: 0.5); floorMask.endPoint = CGPoint(x: 1, y: 0.5)
        case .right: floorMask.startPoint = CGPoint(x: 1, y: 0.5); floorMask.endPoint = CGPoint(x: 0, y: 0.5)
        }

        // Behind the glass: the same image, cropped to exactly where the Dock sits.
        let pill = dock.offsetBy(dx: -floor.minX, dy: -floor.minY)
        pillLayer.frame = pill
        pillLayer.contentsRect = CGRect(x: pill.minX / floor.width, y: pill.minY / floor.height,
                                        width: pill.width / floor.width, height: pill.height / floor.height)
        pillMask.frame = CGRect(origin: .zero, size: pill.size)
        pillMask.contents = Self.featheredMask(size: pill.size, scale: window.backingScaleFactor)
        CATransaction.commit()
        if shown { window.orderFrontRegardless() }
    }

    /// The strip along the screen edge the Dock lives on, as deep as the Dock's reserved area.
    private static func floor(for dock: CGRect, on screen: NSScreen) -> (CGRect, Edge) {
        let f = screen.frame, v = screen.visibleFrame
        let gaps: [(Edge, CGFloat)] = [(.bottom, dock.minY - f.minY), (.left, dock.minX - f.minX), (.right, f.maxX - dock.maxX)]
        let edge = gaps.min { $0.1 < $1.1 }!.0
        switch edge {
        case .bottom:
            let top = max(dock.maxY, v.minY)
            return (CGRect(x: f.minX, y: f.minY, width: f.width, height: top - f.minY), edge)
        case .left:
            let right = max(dock.maxX, v.minX)
            return (CGRect(x: f.minX, y: f.minY, width: right - f.minX, height: f.height), edge)
        case .right:
            let left = min(dock.minX, v.maxX)
            return (CGRect(x: left, y: f.minY, width: f.maxX - left, height: f.height), edge)
        }
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
