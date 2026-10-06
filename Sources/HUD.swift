// HUD.swift: a small dark panel near the bottom of the screen under the pointer, shown for ~1 s.
// It never takes focus and shows over full-screen apps and on every Space.
import AppKit

final class HUD {
    private let panel: NSPanel
    private let icon = NSImageView()
    private let text = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 54),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true
        panel.contentView = fx

        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        text.font = .systemFont(ofSize: 16, weight: .semibold)
        text.textColor = .labelColor
        text.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 12, right: 20)
        row.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            row.topAnchor.constraint(equalTo: fx.topAnchor),
            row.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
    }

    func show(symbol: String, _ message: String, tint: NSColor? = nil, seconds: Double = 1.1) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: message)
        icon.contentTintColor = tint
        text.stringValue = message
        let size = panel.contentView!.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + f.height * 0.14,
                                  width: size.width, height: size.height), display: true)
        }
        hideWork?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self?.panel.animator().alphaValue = 0
            }, completionHandler: { self?.panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
