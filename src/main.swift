import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    let store = UsageStore()
    let updater = UpdateService()
    var dataTimer: Timer?
    var statusTimer: Timer?

    static let popoverSize = NSSize(width: 420, height: 640)

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { self.setup() }
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
        statusItem.button?.action = #selector(toggle(_:))
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let host = NSHostingController(
            rootView: PopoverView(
                store: store,
                updater: updater,
                onRefresh: { [weak self] in self?.store.refresh() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        host.preferredContentSize = Self.popoverSize

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = Self.popoverSize
        popover.contentViewController = host

        store.refresh()
        // 데이터 60초 폴링
        dataTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.refresh() }
        }
        // 메뉴바 카운트다운은 5초마다 갱신
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.updateStatusItem()
        }
    }

    func updateStatusItem() {
        statusItem.button?.title = store.menuBarTitle
    }

    @objc func toggle(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - Entry

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
