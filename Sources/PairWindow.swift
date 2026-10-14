// PairWindow.swift: the "Pair iPhone" window. It shows the pairing QR code (RemoteServer.beginPairing) for
// five minutes, says so when the phone has paired, and closes the pairing when it closes.
import AppKit
import CoreImage

final class PairWindow: NSObject, NSWindowDelegate {
    private let remote: RemoteServer
    private var window: NSWindow?
    private var timer: Timer?
    private var until = Date()
    private var paired = false
    private let note = NSTextField(labelWithString: "")
    private var link = ""

    init(remote: RemoteServer) { self.remote = remote }

    func show() {
        window?.close()
        let p = remote.beginPairing()
        until = Date().addingTimeInterval(300)
        paired = false

        link = p.url.absoluteString
        let code = NSImageView(image: Self.qr(link, side: 260))
        code.imageScaling = .scaleNone
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 10
        code.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(code)
        NSLayoutConstraint.activate([
            code.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            code.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            code.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            code.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
        let title = NSTextField(labelWithString: "Scan with your iPhone's Camera")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString:
            "Open the Camera app on your iPhone and point it at the code, then tap the Squelch link. " +
            "The code pairs one iPhone with \(remote.macName) and works only while this window is open.")
        help.preferredMaxLayoutWidth = 300
        // Apple Vision has no camera for apps: copy the link here and paste it there (Universal Clipboard).
        let copy = NSButton(title: "Copy Link for Apple Vision Pro", target: self, action: #selector(copyLink))
        copy.bezelStyle = .rounded
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, card, help, copy, note])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 348, height: 510),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Pair iPhone"
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.contentView = stack
        w.delegate = self
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func close() { window?.close() }

    @objc private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        NSPasteboard.general.setString(link, forType: .URL)
        Log.i("pair: link copied")
    }

    private func tick() {
        guard let w = window, !paired else { return }
        let left = Int(until.timeIntervalSinceNow)
        if remote.pairingOpen {
            note.stringValue = "This code expires in \(left / 60):\(String(format: "%02d", left % 60))."
        } else if left > 0 {
            // The pairing closed before its time: a phone used it.
            paired = true
            note.stringValue = "Paired. Your iPhone can mute this Mac now."
            note.textColor = .labelColor
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak w] in w?.close() }
        } else {
            w.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        remote.endPairing()
        window = nil
    }

    static func qr(_ text: String, side: CGFloat) -> NSImage {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return NSImage() }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return NSImage() }
        let scale = max(1, (side / out.extent.width).rounded(.down))
        let rep = NSCIImageRep(ciImage: out.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
