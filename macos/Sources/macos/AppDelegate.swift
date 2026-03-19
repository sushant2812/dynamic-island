import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let nowPlaying = NowPlayingService()
    private var panelController: IslandPanelController?
    private let islandState = IslandState()
    private let notifications = NotificationsStore()
    private var clickThroughEnabled = false
    private var clickThroughMenuItem: NSMenuItem?
    private var mouseDownMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        nowPlaying.start()
        let controller = IslandPanelController(rootView: EmptyView())
        panelController = controller
        controller.setExpanded(false)

        controller.setRootView(IslandView(nowPlaying: nowPlaying, islandState: islandState, notifications: notifications))
        controller.show()

        islandState.$expanded
            .receive(on: RunLoop.main)
            .sink { [weak controller] expanded in
                controller?.setExpanded(expanded)
            }
            .store(in: &cancellables)

        nowPlaying.$session
            .receive(on: RunLoop.main)
            .sink { [weak controller] session in
                controller?.setHasSession(session != nil)
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.islandState.expanded else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                    self.islandState.expanded = false
                }
            }
            .store(in: &cancellables)

        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return }
            guard self.islandState.expanded else { return }
            guard let controller = self.panelController else { return }
            let point = NSEvent.mouseLocation
            if !controller.containsScreenPoint(point) {
                Task { @MainActor in
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                        self.islandState.expanded = false
                    }
                }
            }
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule", accessibilityDescription: "Dynamic Island")
        item.button?.target = self
        item.button?.action = #selector(toggleIsland)
        statusItem = item

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle Island", action: #selector(toggleIsland), keyEquivalent: "i"))
        let clickItem = NSMenuItem(title: "Allow clicking through (over apps)",
                                   action: #selector(toggleClickThrough),
                                   keyEquivalent: "")
        clickItem.state = clickThroughEnabled ? .on : .off
        menu.addItem(clickItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
        clickThroughMenuItem = clickItem
    }

    @objc private func toggleIsland() {
        panelController?.toggle()
    }

    @objc private func toggleClickThrough() {
        clickThroughEnabled.toggle()
        clickThroughMenuItem?.state = clickThroughEnabled ? .on : .off
        panelController?.setClickThrough(clickThroughEnabled)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@main
final class MenuBarIslandApp: NSObject {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
