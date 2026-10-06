// QRScanner.swift: VisionKit's live scanner, QR codes only, reporting the first squelch-pair:// link it sees.
import SwiftUI
import VisionKit
import SquelchRemote

struct QRScanner: UIViewControllerRepresentable {
    let found: (URL) -> Void

    /// The hardware can scan (A12 or later) and the camera isn't restricted.
    @MainActor static var canScan: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        // Scanning can only start once the controller is on screen.
        if !vc.isScanning { try? vc.startScanning() }
    }

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (URL) -> Void
        private var done = false

        init(found: @escaping (URL) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in items { take(item, scanner) }
        }

        func dataScanner(_ scanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            take(item, scanner)
        }

        private func take(_ item: RecognizedItem, _ scanner: DataScannerViewController) {
            guard !done, case .barcode(let code) = item, let text = code.payloadStringValue,
                  let url = URL(string: text), RemotePairing(url: url) != nil else { return }
            done = true
            scanner.stopScanning()
            found(url)
        }
    }
}
