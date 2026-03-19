import AppKit
import SwiftUI

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var hitTestBandHeight: CGFloat = 72

    override func hitTest(_ point: NSPoint) -> NSView? {
        let bandRect = NSRect(
            x: bounds.minX,
            y: bounds.maxY - hitTestBandHeight,
            width: bounds.width,
            height: hitTestBandHeight
        )
        guard bandRect.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
final class IslandPanelController {
    private let panel: NSPanel
    private var isClickThroughEnabled = false
    private let hosting: PassthroughHostingView<AnyView>
    private(set) var isExpanded: Bool = false
    private(set) var hasSession: Bool = false

    init(rootView: some View) {
        hosting = PassthroughHostingView(rootView: AnyView(rootView))
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.hitTestBandHeight = 72

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 50),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = isClickThroughEnabled
        panel.contentView = hosting
    }

    func setRootView<V: View>(_ view: V) {
        hosting.rootView = AnyView(view)
    }

    func setClickThrough(_ enabled: Bool) {
        isClickThroughEnabled = enabled
        panel.ignoresMouseEvents = enabled
    }

    func show() {
        positionTopCenter()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    private static let springTiming = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)

    func setHasSession(_ value: Bool) {
        hasSession = value
        guard !isExpanded else { return }

        let targetSize = value
            ? NSSize(width: 380, height: 56)
            : NSSize(width: 200, height: 44)
        hosting.hitTestBandHeight = value ? 72 : 44

        let nextFrame = topCenterFrame(size: targetSize, expanded: false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = Self.springTiming
            panel.animator().setFrame(nextFrame, display: true)
        }
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded

        let targetSize: NSSize
        if expanded {
            hosting.hitTestBandHeight = 160
            targetSize = NSSize(width: 520, height: 120)
        } else if hasSession {
            hosting.hitTestBandHeight = 72
            targetSize = NSSize(width: 380, height: 56)
        } else {
            hosting.hitTestBandHeight = 44
            targetSize = NSSize(width: 200, height: 44)
        }

        let nextFrame = topCenterFrame(size: targetSize, expanded: expanded)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = expanded ? 0.42 : 0.45
            context.timingFunction = Self.springTiming
            panel.animator().setFrame(nextFrame, display: true)
        }
    }

    func containsScreenPoint(_ point: CGPoint) -> Bool {
        panel.frame.contains(point)
    }

    private func topCenterFrame(size: NSSize, expanded: Bool) -> NSRect {
        guard let screen = NSScreen.main else { return panel.frame }
        let frame = screen.frame
        let x = frame.minX + (frame.width - size.width) / 2
        let yNudge: CGFloat = expanded ? 50 : 0
        let y = frame.maxY - size.height - yNudge
        return NSRect(x: round(x), y: round(y), width: size.width, height: size.height)
    }

    private func positionTopCenter() {
        let frame = topCenterFrame(size: panel.frame.size, expanded: isExpanded)
        panel.setFrameOrigin(frame.origin)
    }
}
