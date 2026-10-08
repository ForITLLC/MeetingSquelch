// MicWatcher.swift: which processes are recording a microphone, event-driven, and from which input.
// Same CoreAudio process objects as mic-control/mic-users.swift (macOS 14.2+):
// kAudioHardwarePropertyProcessObjectList plus kAudioProcessPropertyIsRunningInput, and
// kAudioProcessPropertyDevices in the input scope for the devices each one records from.
// Helpers report their own bundle ID (com.microsoft.edgemac.helper), so callers match prefixes.
import CoreAudio
import Foundation

final class MicWatcher {
    private(set) var recording: [String] = []
    // The recording processes' Core Audio objects and bundle IDs, for inputs(). Main thread only.
    private(set) var objects: [AudioObjectID: String] = [:]
    var onChange: (([String]) -> Void)?
    private var watched = Set<AudioObjectID>()

    func start() {
        var a = caAddr(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in
            self?.watchProcesses()
            self?.refresh()
        }
        watchProcesses()
        refresh()
    }

    private func processObjects() -> [AudioObjectID] {
        var a = caAddr(kAudioHardwarePropertyProcessObjectList); var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz) == noErr,
              sz > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids) == noErr
        else { return [] }
        return ids
    }

    private func watchProcesses() {
        for o in processObjects() where !watched.contains(o) {
            var a = caAddr(kAudioProcessPropertyIsRunningInput)
            let st = AudioObjectAddPropertyListenerBlock(o, &a, .main) { [weak self] _, _ in self?.refresh() }
            if st == noErr { watched.insert(o) }
        }
    }

    private func refresh() {
        var objs: [AudioObjectID: String] = [:]
        for o in processObjects() where caU32(o, kAudioProcessPropertyIsRunningInput) == 1 {
            objs[o] = caString(o, kAudioProcessPropertyBundleID)
        }
        objects = objs
        let now = Set(objs.values).sorted()
        guard now != recording else { return }
        recording = now
        Log.i("MIC " + now.map { $0.isEmpty ? "(no-bundle)" : $0 }.joined(separator: " "))
        onChange?(now)
    }

    // The input device each recording process uses right now, read fresh, so a call app that switches
    // its mic mid-call shows up on the next refresh. A handful of Core Audio reads; safe off the main thread.
    static func inputs(_ objects: [AudioObjectID: String]) -> [MicUse] {
        var out: [MicUse] = []
        for (o, bid) in objects.sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
            var a = caAddr(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput); var sz: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(o, &a, 0, nil, &sz) == noErr, sz > 0 else { continue }
            var ids = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(o, &a, 0, nil, &sz, &ids) == noErr else { continue }
            for d in ids.prefix(Int(sz) / MemoryLayout<AudioObjectID>.size) where d != kAudioObjectUnknown {
                out.append(MicUse(bundleID: bid, device: d, name: SystemMic.name(d)))
            }
        }
        return out
    }
}
