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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 400, height: 620)
        popover.contentViewController = NSHostingController(rootView: CompanionPanel(model: model))
        model.changed = { [weak self] in self?.updateIcon() }
        updateIcon()
        if let index = CommandLine.arguments.firstIndex(of: "--performance-report"),
           CommandLine.arguments.count > index + 1 {
            Task { await PerformanceRun.run(model: model, path: CommandLine.arguments[index + 1]) }
        } else { model.start() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        CodexAppServerClient.shutdown()
    }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let remaining = model.remaining
        button.image = QuotaIcon.image(remaining: remaining)
        button.imagePosition = .imageLeading
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
