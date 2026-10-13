import AppKit
import SwiftUI

@main
struct CompanionApp: App {
    @NSApplicationDelegateAdaptor(CompanionDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class CompanionDelegate: NSObject, NSApplicationDelegate {
    private let model = CompanionModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "statusPositionRepairedV1") {
            defaults.set(0, forKey: "NSStatusItem Preferred Position CodexLimitCompanionStatusItem")
            defaults.set(true, forKey: "statusPositionRepairedV1")
        }
        statusItem = NSStatusBar.system.statusItem(withLength: 28)
        // Tahoe must finish registering the item before restoring its saved position.
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.autosaveName = "CodexLimitCompanionStatusItem"
        }
        statusItem.isVisible = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: .leftMouseUp)
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 400, height: 620)
        popover.contentViewController = NSHostingController(rootView: CompanionPanel(model: model))
        model.changed = { [weak self] in self?.updateIcon() }
        updateIcon()
        if let index = CommandLine.arguments.firstIndex(of: "--performance-report"),
           CommandLine.arguments.count > index + 1 {
            Task { await PerformanceRun.run(model: model, path: CommandLine.arguments[index + 1]) }
        } else {
            model.start()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--status-diagnostics"), CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.writeStatusDiagnostics(path) }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.isVisible = true
        updateIcon()
        DispatchQueue.main.async { [weak self] in self?.showPopover() }
        return false
    }
    private func showPopover() {
        guard !popover.isShown, let button = statusItem?.button, let window = button.window,
              StatusAnchor.isValid(window.frame, screens: NSScreen.screens.map(\.frame)) else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    private func writeStatusDiagnostics(_ path: String) {
        guard let button = statusItem?.button else { return }
        let value: [String: Any] = [
            "visible": statusItem.isVisible, "length": statusItem.length,
            "validAnchor": button.window.map { StatusAnchor.isValid($0.frame, screens: NSScreen.screens.map(\.frame)) } ?? false,
            "buttonBounds": NSStringFromRect(button.bounds),
            "windowFrame": button.window.map { NSStringFromRect($0.frame) } ?? "nil",
            "screenFrame": button.window?.screen.map { NSStringFromRect($0.frame) } ?? "nil",
            "hasImage": button.image != nil, "imageSize": button.image.map { NSStringFromSize($0.size) } ?? "nil"
        ]
        try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.flushLogs()
        CodexAppServerClient.shutdown()
    }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else { showPopover() }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let remaining = model.remaining
        button.image = QuotaIcon.image(remaining: remaining)
        statusItem.length = model.showPercent ? 64 : 28
        button.imagePosition = model.showPercent ? .imageLeading : .imageOnly
        button.title = model.showPercent ? remaining.map { " \(Int($0))%" } ?? " —" : ""
        let text = remaining.map { "Codex 剩余 \(Int($0))%" } ?? (model.error == nil ? "Codex 正在读取额度" : "Codex 额度读取失败")
        button.toolTip = text
        button.setAccessibilityLabel(text + "，点击打开额度面板")
    }
}

enum QuotaIcon {
    static var mark: NSImage {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("CodexLimitCompanion_CodexLimitCompanion.bundle")
        let resources = packaged.flatMap { Bundle(url: $0) } ?? Bundle.module
        let url = resources.url(forResource: "gpt-mark", withExtension: "png")!
        return NSImage(contentsOf: url)!
    }
    static func image(remaining: Double?) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let result = NSImage(size: size, flipped: false) { rect in
            let box = rect.insetBy(dx: 2, dy: 2)
            let silhouette = NSImage(size: size, flipped: false) { _ in
                mark.draw(in: box)
                NSColor.labelColor.withAlphaComponent(0.34).setFill()
                rect.fill(using: .sourceIn)
                return true
            }
            silhouette.draw(in: rect)
            if let remaining {
                let color: NSColor = remaining > 30 ? .systemTeal : remaining > 10 ? .systemOrange : .systemRed
                let fill = NSImage(size: size, flipped: false) { _ in
                    mark.draw(in: box)
                    color.setFill(); rect.fill(using: .sourceIn); return true
                }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: NSRect(x: 0, y: 2, width: 22, height: 18 * remaining / 100)).addClip()
                fill.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                NSColor.secondaryLabelColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: 16, y: 1, width: 5, height: 5)).fill()
            }
            return true
        }
        result.isTemplate = false
        return result
    }
}

/// Status items must be hosted along a screen's top edge before presenting a popover.
enum StatusAnchor {
    static func isValid(_ frame: NSRect, screens: [NSRect]) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        return screens.contains { screen in
            frame.midX >= screen.minX && frame.midX <= screen.maxX &&
            frame.midY >= screen.maxY - 64 && frame.midY <= screen.maxY + 8
        }
    }
}
