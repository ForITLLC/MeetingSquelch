// MicWatcher.swift: which processes are recording a microphone, event-driven.
// Same CoreAudio process objects as mic-control/mic-users.swift (macOS 14.2+):
// kAudioHardwarePropertyProcessObjectList plus kAudioProcessPropertyIsRunningInput.
// Helpers report their own bundle ID (com.microsoft.edgemac.helper), so callers match prefixes.
import CoreAudio
import Foundation

final class MicWatcher {
    private(set) var recording: [String] = []
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
        let now = Set(processObjects()
            .filter { caU32($0, kAudioProcessPropertyIsRunningInput) == 1 }
            .map { caString($0, kAudioProcessPropertyBundleID) })
            .sorted()
        guard now != recording else { return }
        recording = now
        Log.i("MIC " + now.map { $0.isEmpty ? "(no-bundle)" : $0 }.joined(separator: " "))
        onChange?(now)
    }
}
