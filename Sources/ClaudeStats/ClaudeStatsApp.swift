import SwiftUI
import AppKit

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar agent, no dock icon
        app.run()
    }
}

/// Borderless key-able panel so o/m/esc keystrokes reach the popup.
final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = StatsEngine()
    private let ui = UIState()
    private var statusItem: NSStatusItem!
    private var panel: StatusPanel!
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var ready = false
    private var pendingToggle = false

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.menuIcon
            button.action = #selector(buttonClicked)
            button.target = self
        }

        let host = NSHostingView(rootView:
            ContentView(engine: engine, ui: ui)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        )
        host.layoutSubtreeIfNeeded()

        panel = StatusPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.contentView = host

        ready = true
        if pendingToggle { pendingToggle = false; toggle() }
    }

    // MARK: toggle / show / close

    @objc private func buttonClicked() { toggle() }

    private var isOpen: Bool { panel.isVisible }

    @objc private func toggle() {
        guard ready else { pendingToggle = true; return }
        if isOpen { close() } else { show() }
    }

    private func show() {
        engine.refresh()
        // resize to current content, then position under the status icon
        if let host = panel.contentView { host.layoutSubtreeIfNeeded(); panel.setContentSize(host.fittingSize) }
        position()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installMonitors()
    }

    private func close() {
        panel.orderOut(nil)
        removeMonitors()
    }

    private func position() {
        guard let button = statusItem.button, let bw = button.window else { return }
        let btn = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        var x = btn.midX - size.width / 2
        let y = btn.minY - size.height - 4          // hang just below the menu bar
        if let vis = (bw.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, vis.minX + 8), vis.maxX - size.width - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: external triggers (Raycast / Finder / Dock)

    func application(_ app: NSApplication, open urls: [URL]) { toggle() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        toggle(); return true
    }

    // MARK: monitors — keyboard + click-outside-to-close

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // don't hijack shortcuts while typing in a text field (calibration)
            if self.panel.firstResponder is NSTextView { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "o": self.ui.tab = .overview;  return nil
            case "m": self.ui.tab = .models;    return nil
            case "1": self.engine.window = .all; return nil
            case "2": self.engine.window = .d30; return nil
            case "3": self.engine.window = .d7;  return nil
            default:
                switch event.keyCode {
                case 53: self.close(); return nil                       // esc
                case 123, 126: self.ui.tab = .overview; return nil      // left / up
                case 124, 125: self.ui.tab = .models;   return nil      // right / down
                default: return event
                }
            }
        }
        // close when clicking anywhere outside the panel (but let the icon toggle itself)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            if let b = self.statusItem.button, let bw = b.window {
                let btn = bw.convertToScreen(b.convert(b.bounds, to: nil))
                if btn.contains(mouse) { return }   // icon click → buttonClicked handles toggle
            }
            self.close()
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    // MARK: white template glyph from the Claude burst

    static let menuIcon: NSImage = {
        if let url = Bundle.module.url(forResource: "icon", withExtension: "png"),
           let raw = NSImage(contentsOf: url),
           let tmpl = makeTemplate(from: raw) {
            return tmpl
        }
        let sym = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude Stats")!
        sym.isTemplate = true
        return sym
    }()

    private static func makeTemplate(from raw: NSImage) -> NSImage? {
        guard let cg = raw.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        let cs = CGColorSpaceCreateDeviceRGB()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(1, max(0, (x - a) / (b - a)))
            return t * t * (3 - 2 * t)
        }
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2]), a = Double(px[i + 3])
            let lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            let keep = a > 10 ? smoothstep(0.62, 0.82, lum) : 0
            let v = UInt8(keep * 255)
            px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = v   // premultiplied white
        }
        guard let out = ctx.makeImage() else { return nil }
        let img = NSImage(cgImage: out, size: NSSize(width: 18, height: 18))
        img.isTemplate = true
        return img
    }
}
