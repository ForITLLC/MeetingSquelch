// ThisDevice.swift: what the remote calls the device it runs on, and how that device takes the Mac's pairing
// code. An iPhone or iPad scans the QR code; Apple Vision Pro gives apps no camera scanner, so there the code's
// squelch-pair:// link is pasted (the iPhone Camera app copies it, Universal Clipboard brings it over).
import Foundation

public enum ThisDevice {
    #if os(visionOS)
    public static let noun = "Apple Vision Pro"
    public static let takeCode = "paste the link of the code it shows"
    public static let takeNewCode = "paste the link of the new code"
    #else
    /// The one iPhone app also runs on iPad, so this is read once, from the device.
    public static let noun: String = isPad ? "iPad" : "iPhone"
    public static let takeCode = "scan the code"
    public static let takeNewCode = "scan the new code"
    #endif

    static var isPad: Bool {
        #if os(iOS)
        return model.hasPrefix("iPad")
        #else
        return false
        #endif
    }

    /// The hardware model, "iPhone17,1" or "iPad16,3". Read with sysctl rather than UIDevice, which belongs to the
    /// main actor, because an App Intent can ask from any thread. The simulator names the device it plays.
    static var model: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }
}
